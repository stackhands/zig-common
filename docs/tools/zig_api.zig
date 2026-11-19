//! Write the API reference of a Zig module as MyST pages for Sphinx.
//!
//!     zig run docs/tools/zig_api.zig -- --module NAME --root FILE --out DIR
//!         [--source-url URL] [--title TEXT] [--follow-private-imports]
//!
//! The parser is std.zig.Ast, the one the compiler uses. From the root file
//! it follows every `@import("x.zig")` bound to a `pub` declaration (and to
//! any declaration with --follow-private-imports, which an executable needs:
//! its files are rarely imported as `pub`). Each file becomes one page,
//! `<module path>.md`, holding its `//!` comment and one `zig:` directive
//! per `pub` declaration, with its `///` comment as the body. Fields of a
//! container and the `pub` declarations inside it are nested under it. A
//! file imported along several paths takes the shortest of `pub` imports,
//! or of any imports when there is none. `index.md` lists the pages. An import of another package, such as
//! `@import("zig_common")`, is not followed; intersphinx links to that
//! package's own site.
//!
//! `{ref}` in the source URL becomes $DOCS_SOURCE_REF, else $GITHUB_SHA,
//! else `main`, so a page built in CI links to the commit it was built from.
//! DIR is emptied first: it holds only generated pages.
const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const usage =
    \\usage: zig_api --module NAME --root FILE --out DIR [--source-url URL]
    \\               [--title TEXT] [--follow-private-imports]
    \\
;

const Options = struct {
    module: []const u8 = "",
    root: []const u8 = "",
    out: []const u8 = "",
    source_url: []const u8 = "",
    title: []const u8 = "",
    follow_private: bool = false,
};

const Kind = enum {
    module,
    type,
    errorset,
    function,
    constant,
    variable,

    fn directive(k: Kind) []const u8 {
        return switch (k) {
            .module => "zig:module",
            .type => "zig:type",
            .errorset => "zig:errorset",
            .function => "zig:function",
            .constant => "zig:constant",
            .variable => "zig:variable",
        };
    }

    fn heading(k: Kind) []const u8 {
        return switch (k) {
            .module => "Modules",
            .type => "Types",
            .errorset => "Error sets",
            .function => "Functions",
            .constant => "Constants",
            .variable => "Variables",
        };
    }
};

/// One file to document: the dotted name it is published under and its path.
const Page = struct {
    fqn: []const u8,
    path: []const u8,
    summary: []const u8 = "",
    /// Reached from the root through `pub` imports alone, so the autodoc
    /// site, which shows only those, has its declarations.
    public: bool = false,
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    pages: std.ArrayList(Page) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig_api: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--follow-private-imports")) {
            opts.follow_private = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        }
        if (i + 1 >= args.len) fail("{s} needs a value\n{s}", .{ a, usage });
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--module")) {
            opts.module = v;
        } else if (std.mem.eql(u8, a, "--root")) {
            opts.root = v;
        } else if (std.mem.eql(u8, a, "--out")) {
            opts.out = v;
        } else if (std.mem.eql(u8, a, "--source-url")) {
            opts.source_url = v;
        } else if (std.mem.eql(u8, a, "--title")) {
            opts.title = v;
        } else {
            fail("unknown option {s}\n{s}", .{ a, usage });
        }
    }
    if (opts.module.len == 0 or opts.root.len == 0 or opts.out.len == 0) fail("{s}", .{usage});
    const ref = init.environ_map.get("DOCS_SOURCE_REF") orelse init.environ_map.get("GITHUB_SHA") orelse "main";
    opts.source_url = try std.mem.replaceOwned(u8, arena, opts.source_url, "{ref}", ref);

    var ctx: Ctx = .{ .gpa = arena, .io = init.io, .opts = opts };
    try Io.Dir.cwd().deleteTree(init.io, opts.out);
    try Io.Dir.cwd().createDirPath(init.io, opts.out);
    try collect(&ctx);
    for (ctx.pages.items) |*page| try writePage(&ctx, page);
    try writeIndex(&ctx);
}

fn readSource(ctx: *Ctx, path: []const u8) ![:0]const u8 {
    return Io.Dir.cwd().readFileAllocOptions(ctx.io, path, ctx.gpa, .limited(64 << 20), .of(u8), 0) catch |err|
        fail("cannot read {s}: {s}", .{ path, @errorName(err) });
}

fn parse(ctx: *Ctx, path: []const u8) !Ast {
    const source = try readSource(ctx, path);
    const tree = try Ast.parse(ctx.gpa, source, .{});
    if (tree.errors.len != 0) {
        const e = tree.errors[0];
        const loc = tree.tokenLocation(0, e.token);
        fail("{s}:{d}:{d}: does not parse ({s})", .{ path, loc.line + 1, loc.column + 1, @tagName(e.tag) });
    }
    return tree;
}

/// Find the files to document, breadth first, so each gets its shortest
/// name: through `pub` imports when it has one, which is the name the
/// autodoc knows, else through any import.
fn collect(ctx: *Ctx) !void {
    try addPage(ctx, ctx.opts.module, ctx.opts.root, true);
    try walk(ctx, true);
    if (ctx.opts.follow_private) try walk(ctx, false);
}

/// Add the files imported by the pages found so far, and by the pages
/// added meanwhile: by `pub` declarations of public pages, or by any
/// declaration of any page.
fn walk(ctx: *Ctx, public: bool) !void {
    var i: usize = 0;
    while (i < ctx.pages.items.len) : (i += 1) {
        const page = ctx.pages.items[i];
        if (public and !page.public) continue;
        var tree = try parse(ctx, page.path);
        for (tree.rootDecls()) |decl| {
            const vd = tree.fullVarDecl(decl) orelse continue;
            if (public and vd.visib_token == null) continue;
            const target = importPath(&tree, vd) orelse continue;
            const name = tree.tokenSlice(vd.ast.mut_token + 1);
            const fqn = try std.fmt.allocPrint(ctx.gpa, "{s}.{s}", .{ page.fqn, name });
            try addPage(ctx, fqn, try importedFile(ctx, page.path, target), public);
        }
    }
}

fn addPage(ctx: *Ctx, fqn: []const u8, path: []const u8, public: bool) !void {
    const gop = try ctx.seen.getOrPut(ctx.gpa, path);
    if (gop.found_existing) return;
    var tree = try parse(ctx, path);
    try ctx.pages.append(ctx.gpa, .{
        .fqn = fqn,
        .path = path,
        .summary = try firstSentence(ctx.gpa, try containerDoc(ctx.gpa, &tree)),
        .public = public,
    });
}

/// The path of the file that `@import(target)` in the file `from` names.
fn importedFile(ctx: *Ctx, from: []const u8, target: []const u8) ![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ std.fs.path.dirname(from) orelse ".", target });
}

/// The dotted name of the page for the file `@import(target)` in the file
/// `from` names; another path to that file may have given it its name.
fn pageOf(ctx: *Ctx, from: []const u8, target: []const u8) ![]const u8 {
    const path = try importedFile(ctx, from, target);
    for (ctx.pages.items) |page| {
        if (std.mem.eql(u8, page.path, path)) return page.fqn;
    }
    fail("{s} imports {s}, which has no page", .{ from, path });
}

/// The file a declaration `@import`s, when it names a `.zig` file.
fn importPath(tree: *const Ast, vd: Ast.full.VarDecl) ?[]const u8 {
    const init_node = vd.ast.init_node.unwrap() orelse return null;
    switch (tree.nodeTag(init_node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return null;
    var buf: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, init_node) orelse return null;
    if (params.len != 1 or tree.nodeTag(params[0]) != .string_literal) return null;
    const lit = tree.tokenSlice(tree.nodeMainToken(params[0]));
    if (lit.len < 2) return null;
    const name = lit[1 .. lit.len - 1];
    if (!std.mem.endsWith(u8, name, ".zig")) return null;
    return name;
}

/// The `//!` lines at the top of a file, without the marker.
fn containerDoc(gpa: Allocator, tree: *const Ast) ![]const u8 {
    var out: Writer.Allocating = .init(gpa);
    var tok: Ast.TokenIndex = 0;
    while (tok < tree.tokens.len and tree.tokenTag(tok) == .container_doc_comment) : (tok += 1) {
        try out.writer.print("{s}\n", .{stripMarker(tree.tokenSlice(tok))});
    }
    return out.written();
}

/// The `///` lines directly above the token, without the marker.
fn docComment(gpa: Allocator, tree: *const Ast, first: Ast.TokenIndex) ![]const u8 {
    var start = first;
    while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) start -= 1;
    var out: Writer.Allocating = .init(gpa);
    var tok = start;
    while (tok < first) : (tok += 1) {
        try out.writer.print("{s}\n", .{stripMarker(tree.tokenSlice(tok))});
    }
    return out.written();
}

/// The name an identifier token spells: `@"rename-fallback"` is
/// rename-fallback. Anchors and cross-references use this form; the
/// signature keeps the source's.
fn identName(token: []const u8) []const u8 {
    if (token.len >= 3 and std.mem.startsWith(u8, token, "@\"") and token[token.len - 1] == '"')
        return token[2 .. token.len - 1];
    return token;
}

fn stripMarker(line: []const u8) []const u8 {
    var s = line[3..];
    if (s.len > 0 and s[0] == ' ') s = s[1..];
    return std.mem.trimEnd(u8, s, " \t\r");
}

fn firstSentence(gpa: Allocator, doc: []const u8) ![]const u8 {
    const para_end = std.mem.indexOf(u8, doc, "\n\n") orelse doc.len;
    const para = try collapse(gpa, doc[0..para_end]);
    var i: usize = 0;
    while (i + 1 < para.len) : (i += 1) {
        if (para[i] == '.' and para[i + 1] == ' ') return para[0 .. i + 1];
    }
    return para;
}

/// Source text with every run of whitespace, newlines included, made one space.
fn collapse(gpa: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(gpa, ' ');
        space = false;
        // zig fmt leaves a comma before a closing bracket on a wrapped list.
        if ((c == ')' or c == '}' or c == ']') and out.items.len > 1 and
            out.items[out.items.len - 1] == ' ' and out.items[out.items.len - 2] == ',')
        {
            out.items.len -= 2;
        }
        try out.append(gpa, c);
    }
    return out.items;
}

fn tokenText(tree: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) []const u8 {
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    return tree.source[start..end];
}

fn lineOf(tree: *const Ast, tok: Ast.TokenIndex) usize {
    return tree.tokenLocation(0, tok).line + 1;
}

const Member = struct {
    kind: Kind,
    name: []const u8,
    signature: []const u8,
    doc: []const u8,
    line: usize,
    /// For a container: its node, to document fields and nested declarations.
    container: ?Ast.Node.Index = null,
    /// For an error set: its node, to list the error names.
    errors: ?Ast.Node.Index = null,
    /// For an imported file: the `@import` operand, such as "proc.zig".
    import: []const u8 = "",
};

fn isContainer(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => true,
        else => false,
    };
}

fn isTypeName(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]) or std.mem.endsWith(u8, name, "_t");
}

/// The declarations of one container worth a directive: `pub` ones, plus
/// every field. Returns them in source order.
fn members(ctx: *Ctx, tree: *const Ast, decls: []const Ast.Node.Index, fields: *std.ArrayList(Member)) !std.ArrayList(Member) {
    var list: std.ArrayList(Member) = .empty;
    const gpa = ctx.gpa;
    for (decls) |decl| {
        switch (tree.nodeTag(decl)) {
            .container_field_init, .container_field_align, .container_field => {
                var cf = tree.fullContainerField(decl).?;
                cf.convertToNonTupleLike(tree);
                if (cf.ast.tuple_like) continue;
                const first = cf.firstToken();
                try fields.append(gpa, .{
                    .kind = .constant,
                    .name = identName(tree.tokenSlice(cf.ast.main_token)),
                    .signature = try collapse(gpa, tokenText(tree, first, tree.lastToken(decl))),
                    .doc = try docComment(gpa, tree, first),
                    .line = lineOf(tree, first),
                });
            },
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                var buf: [1]Ast.Node.Index = undefined;
                const fp = tree.fullFnProto(&buf, decl).?;
                if (fp.visib_token == null) continue;
                const name_tok = fp.name_token orelse continue;
                const proto = if (tree.nodeTag(decl) == .fn_decl) tree.nodeData(decl).node_and_node[0] else decl;
                try list.append(gpa, .{
                    .kind = .function,
                    .name = identName(tree.tokenSlice(name_tok)),
                    .signature = try collapse(gpa, tokenText(tree, fp.firstToken(), tree.lastToken(proto))),
                    .doc = try docComment(gpa, tree, fp.firstToken()),
                    .line = lineOf(tree, fp.firstToken()),
                });
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const vd = tree.fullVarDecl(decl).?;
                if (vd.visib_token == null) continue;
                const name = identName(tree.tokenSlice(vd.ast.mut_token + 1));
                const first = vd.firstToken();
                var m: Member = .{
                    .kind = if (tree.tokenTag(vd.ast.mut_token) == .keyword_var) .variable else .constant,
                    .name = name,
                    .signature = "",
                    .doc = try docComment(gpa, tree, first),
                    .line = lineOf(tree, first),
                };
                const init_node = vd.ast.init_node.unwrap();
                const head_end: Ast.TokenIndex = if (init_node) |n| tree.firstToken(n) - 1 else tree.lastToken(decl);
                const head = try collapse(gpa, tokenText(tree, first, head_end));
                if (init_node) |n| {
                    if (importPath(tree, vd)) |target| {
                        m.kind = .module;
                        m.import = target;
                        m.signature = try collapse(gpa, tokenText(tree, first, tree.lastToken(n)));
                    } else if (m.kind == .constant and isContainer(tree, n)) {
                        var cbuf: [2]Ast.Node.Index = undefined;
                        const cd = tree.fullContainerDecl(&cbuf, n).?;
                        const lbrace = brace: {
                            var t = cd.ast.main_token;
                            while (tree.tokenTag(t) != .l_brace) t += 1;
                            break :brace t;
                        };
                        m.kind = .type;
                        m.container = n;
                        m.signature = try std.fmt.allocPrint(gpa, "{s} {s}", .{ head, try collapse(gpa, tokenText(tree, tree.firstToken(n), lbrace - 1)) });
                    } else if (m.kind == .constant and (tree.nodeTag(n) == .error_set_decl or tree.nodeTag(n) == .merge_error_sets)) {
                        m.kind = .errorset;
                        m.errors = n;
                        m.signature = try std.fmt.allocPrint(gpa, "{s} {s}", .{ head, if (tree.nodeTag(n) == .error_set_decl) "error{...}" else try collapse(gpa, tree.getNodeSource(n)) });
                    } else {
                        const value = try collapse(gpa, tree.getNodeSource(n));
                        if (m.kind == .constant and isTypeName(name)) m.kind = .type;
                        m.signature = if (value.len <= 72 and std.mem.indexOfScalar(u8, value, '{') == null)
                            try std.fmt.allocPrint(gpa, "{s} {s}", .{ head, value })
                        else
                            try std.fmt.allocPrint(gpa, "{s} ...", .{head});
                    }
                } else {
                    m.signature = head;
                }
                try list.append(gpa, m);
            },
            else => {},
        }
    }
    return list;
}

fn writePage(ctx: *Ctx, page: *Page) !void {
    const gpa = ctx.gpa;
    var tree = try parse(ctx, page.path);
    var out: Writer.Allocating = .init(gpa);
    const w = &out.writer;

    try w.print("# {s}\n\n", .{page.fqn});
    try w.print("::::{{zig:module}} {s}\n:file: {s}\n", .{ page.fqn, page.path });
    if (ctx.opts.source_url.len > 0) try w.print(":source: {s}{s}\n", .{ ctx.opts.source_url, page.path });
    if (!page.public) try w.writeAll(":no-autodoc:\n");
    try w.writeAll("\n");
    try writeDoc(w, try containerDoc(gpa, &tree));
    try w.writeAll("::::\n\n");

    var fields: std.ArrayList(Member) = .empty;
    const list = try members(ctx, &tree, tree.rootDecls(), &fields);
    inline for (.{ Kind.module, Kind.type, Kind.errorset, Kind.function, Kind.constant, Kind.variable }) |kind| {
        var any = false;
        for (list.items) |m| {
            if (m.kind != kind) continue;
            if (!any) try w.print("## {s}\n\n", .{kind.heading()});
            any = true;
            if (kind == .module) {
                // The imported file's own page declares the module.
                const target = try pageOf(ctx, page.path, m.import);
                try w.print("- {{zig:mod}}`{s}`: ", .{target});
                try writeProse(w, summaryOf(ctx, target));
                try w.writeAll("\n");
            } else {
                try writeMember(ctx, w, &tree, page, page.fqn, m);
            }
        }
        if (kind == .module and any) try w.writeAll("\n");
    }

    const name = try std.fmt.allocPrint(gpa, "{s}.md", .{page.fqn});
    var dir = try Io.Dir.cwd().openDir(ctx.io, ctx.opts.out, .{});
    defer dir.close(ctx.io);
    try dir.writeFile(ctx.io, .{ .sub_path = name, .data = out.written() });
}

fn summaryOf(ctx: *Ctx, fqn: []const u8) []const u8 {
    for (ctx.pages.items) |page| {
        if (std.mem.eql(u8, page.fqn, fqn)) return page.summary;
    }
    return "";
}

/// Colons for a directive that holds `depth` levels of nested directives.
fn fence(gpa: Allocator, depth: usize) ![]const u8 {
    const f = try gpa.alloc(u8, 3 + depth);
    @memset(f, ':');
    return f;
}

fn nesting(ctx: *Ctx, tree: *const Ast, m: Member) !usize {
    const n = m.container orelse return if (m.errors != null) 1 else 0;
    var cbuf: [2]Ast.Node.Index = undefined;
    const cd = tree.fullContainerDecl(&cbuf, n).?;
    var fields: std.ArrayList(Member) = .empty;
    const inner = try members(ctx, tree, cd.ast.members, &fields);
    var deepest: usize = if (fields.items.len > 0) 1 else 0;
    for (inner.items) |child| deepest = @max(deepest, 1 + try nesting(ctx, tree, child));
    return deepest;
}

fn writeMember(ctx: *Ctx, w: *Writer, tree: *const Ast, page: *const Page, parent: []const u8, m: Member) !void {
    const gpa = ctx.gpa;
    const fqn = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ parent, m.name });
    const colons = try fence(gpa, try nesting(ctx, tree, m));
    try w.print("{s}{{{s}}} {s}\n", .{ colons, m.kind.directive(), fqn });
    try w.print(":signature: {s}\n", .{m.signature});
    if (ctx.opts.source_url.len > 0) try w.print(":source: {s}{s}#L{d}\n", .{ ctx.opts.source_url, page.path, m.line });
    if (!page.public) try w.writeAll(":no-autodoc:\n");
    try w.writeAll("\n");
    try writeDoc(w, m.doc);

    if (m.errors) |n| try writeErrors(ctx, w, tree, n, fqn);
    if (m.container) |n| {
        var cbuf: [2]Ast.Node.Index = undefined;
        const cd = tree.fullContainerDecl(&cbuf, n).?;
        var fields: std.ArrayList(Member) = .empty;
        const inner = try members(ctx, tree, cd.ast.members, &fields);
        for (fields.items) |f| {
            try w.print(":::{{zig:field}} {s}.{s}\n:signature: {s}\n", .{ fqn, f.name, f.signature });
            if (ctx.opts.source_url.len > 0) try w.print(":source: {s}{s}#L{d}\n", .{ ctx.opts.source_url, page.path, f.line });
            try w.writeAll("\n");
            try writeDoc(w, f.doc);
            try w.writeAll(":::\n\n");
        }
        for (inner.items) |child| try writeMember(ctx, w, tree, page, fqn, child);
    }
    try w.print("{s}\n\n", .{colons});
}

/// Each name of an `error{...}` set, with its `///` comment.
fn writeErrors(ctx: *Ctx, w: *Writer, tree: *const Ast, node: Ast.Node.Index, fqn: []const u8) !void {
    if (tree.nodeTag(node) != .error_set_decl) return;
    const lbrace, const rbrace = tree.nodeData(node).token_and_token;
    var tok = lbrace + 1;
    while (tok < rbrace) : (tok += 1) {
        if (tree.tokenTag(tok) != .identifier) continue;
        try w.print(":::{{zig:error}} {s}.{s}\n:signature: error.{s}\n\n", .{ fqn, identName(tree.tokenSlice(tok)), tree.tokenSlice(tok) });
        try writeDoc(w, try docComment(ctx.gpa, tree, tok));
        try w.writeAll(":::\n\n");
    }
}

/// A doc comment as MyST: Markdown already, except that a heading cannot sit
/// inside a directive, so it becomes a bold line.
fn writeDoc(w: *Writer, doc: []const u8) !void {
    if (std.mem.trim(u8, doc, " \n").len == 0) return;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, doc, "\n"), '\n');
    var in_code = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
            in_code = !in_code;
            try w.print("{s}\n", .{line});
            continue;
        }
        if (in_code) {
            try w.print("{s}\n", .{line});
        } else if (std.mem.startsWith(u8, line, "#")) {
            const text = std.mem.trim(u8, std.mem.trimStart(u8, line, "#"), " ");
            try w.writeAll("**");
            try writeProse(w, text);
            try w.writeAll("**\n");
        } else {
            try writeProse(w, line);
            try w.writeAll("\n");
        }
    }
    try w.writeAll("\n");
}

/// One line of doc comment prose, with the syntax MyST adds to Markdown, and
/// Zig's autodoc does not have, escaped outside code spans: a footnote
/// reference `[^x]` (a regular expression's negated class) and a `%` comment
/// line.
fn writeProse(w: *Writer, line: []const u8) !void {
    return writeEscaped(w, line, false);
}

/// writeProse for a table cell, where a pipe ends the cell, inside a code
/// span too.
fn writeCell(w: *Writer, text: []const u8) !void {
    return writeEscaped(w, text, true);
}

fn writeEscaped(w: *Writer, line: []const u8, cell: bool) !void {
    const indent = line.len - std.mem.trimStart(u8, line, " ").len;
    var in_span = false;
    for (line, 0..) |c, i| {
        if (c == '`') in_span = !in_span;
        const footnote = !in_span and c == '[' and i + 1 < line.len and line[i + 1] == '^';
        const comment = i == indent and c == '%';
        if (footnote or comment or (cell and c == '|')) try w.writeByte('\\');
        try w.writeByte(c);
    }
}

fn writeIndex(ctx: *Ctx) !void {
    var out: Writer.Allocating = .init(ctx.gpa);
    const w = &out.writer;
    const title = if (ctx.opts.title.len > 0) ctx.opts.title else "Zig API";
    try w.print("# {s}\n\n", .{title});
    try w.print("Generated from the doc comments of `{s}` by `docs/tools/zig_api.zig`.\n", .{ctx.opts.module});
    try w.writeAll("Each page is one source file; the `pub` declarations are grouped by kind in source order.\n");
    try w.writeAll("Every declaration links to its source line and, where the {zig:autodoc}`Zig autodoc </>` build has it, to the same declaration there.\n");
    try w.writeAll("\n| Module | Summary |\n|---|---|\n");
    for (ctx.pages.items) |page| {
        try w.print("| {{zig:mod}}`{s}` | ", .{page.fqn});
        try writeCell(w, page.summary);
        try w.writeAll(" |\n");
    }
    try w.writeAll("\n```{toctree}\n:hidden:\n:maxdepth: 1\n\n");
    for (ctx.pages.items) |page| try w.print("{s}\n", .{page.fqn});
    try w.writeAll("```\n");
    var dir = try Io.Dir.cwd().openDir(ctx.io, ctx.opts.out, .{});
    defer dir.close(ctx.io);
    try dir.writeFile(ctx.io, .{ .sub_path = "index.md", .data = out.written() });
}
