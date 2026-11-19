"""A Sphinx domain for Zig declarations.

docs/tools/zig_api.zig writes one ``zig:`` directive per public declaration::

    :::{zig:function} zig_common.proc.run
    :signature: pub fn run(gpa: Allocator, argv: []const []const u8, ...) Error!Result
    :source: https://github.com/stackhands/zig-common/blob/<ref>/src/proc.zig#L120

    The doc comment, as Markdown.
    :::

The argument is the fully qualified name; it is the HTML anchor and the
key for cross-references and for the objects.inv inventory, so other
stackhands sites reach it through intersphinx. Roles: ``zig:mod``,
``zig:type``, ``zig:fn``, ``zig:const``, ``zig:var``, ``zig:field``,
``zig:err``, and ``zig:obj`` for any kind. A target matches a full name, or
failing that a unique dotted suffix (``proc.run``); ``~`` before the target
shows only its last part. ``zig:autodoc`` links into the autodoc site at
``zig_autodoc_root``, which every directive also links to.
"""

from __future__ import annotations

import posixpath
import re
from typing import Any, ClassVar, Iterable

from docutils import nodes
from docutils.nodes import Element, Node
from docutils.parsers.rst import directives
from sphinx import addnodes
from sphinx.addnodes import desc_signature, pending_xref
from sphinx.application import Sphinx
from sphinx.builders import Builder
from sphinx.directives import ObjectDescription
from sphinx.domains import Domain, ObjType
from sphinx.environment import BuildEnvironment
from sphinx.roles import XRefRole
from sphinx.util import logging
from sphinx.util.docutils import SphinxRole
from sphinx.util.nodes import make_refnode, split_explicit_title

logger = logging.getLogger(__name__)

LABELS = {
    "module": "module",
    "type": "type",
    "errorset": "error set",
    "function": "function",
    "constant": "constant",
    "variable": "variable",
    "field": "field",
    "error": "error",
}


def autodoc_href(env: BuildEnvironment, fqn: str) -> str | None:
    """The autodoc URL of *fqn*, relative to the page being read."""
    root = env.config.zig_autodoc_root
    if not root:
        return None
    up = posixpath.relpath(".", posixpath.dirname(env.docname) or ".")
    base = posixpath.normpath(posixpath.join(up, root)) + "/"
    fqn = fqn.strip("/")
    return base + ("#" + fqn if fqn else "")


def link(text: str, href: str, cls: str) -> nodes.reference:
    ref = nodes.reference("", "", internal=False, refuri=href, classes=[cls])
    ref += nodes.inline(text, text)
    return ref


class ZigObject(ObjectDescription[str]):
    """One declaration; its argument is the fully qualified name."""

    has_content = True
    required_arguments = 1
    final_argument_whitespace = False
    option_spec: ClassVar[dict[str, Any]] = {
        "signature": directives.unchanged,
        "source": directives.unchanged,
        "file": directives.unchanged,
        "no-autodoc": directives.flag,
        "no-index": directives.flag,
        "no-index-entry": directives.flag,
        "no-contents-entry": directives.flag,
    }

    def handle_signature(self, sig: str, signode: desc_signature) -> str:
        fqn = sig.strip()
        short = fqn.rsplit(".", 1)[-1]
        text = self.options.get("signature") or ("module " + fqn if self.objtype == "module" else short)
        signode["fullname"] = fqn
        match = re.search(r"(?<![\w@])" + re.escape(short) + r"(?!\w)", text)
        if self.objtype == "module":
            signode += addnodes.desc_annotation("module ", "module ")
            signode += addnodes.desc_name(fqn, fqn)
            if self.options.get("file"):
                path = "  " + self.options["file"]
                signode += nodes.inline(path, path, classes=["zig-sig-rest"])
        elif match is None:
            signode += addnodes.desc_name(text, text)
        else:
            before, after = text[: match.start()], text[match.end():]
            if before:
                signode += addnodes.desc_annotation(before, before)
            signode += addnodes.desc_name(short, short)
            if after:
                signode += nodes.inline(after, after, classes=["zig-sig-rest"])
        source = self.options.get("source")
        if source:
            signode += link("[source]", source, "zig-source-link")
        if self.objtype not in ("field", "error") and "no-autodoc" not in self.options:
            href = autodoc_href(self.env, fqn)
            if href:
                signode += link("[autodoc]", href, "zig-autodoc-link")
        return fqn

    def add_target_and_index(self, name: str, sig: str, signode: desc_signature) -> None:
        # The page title of a module named like a slug ("eb-local") already
        # owns the bare id. Sphinx writes anchors into href attributes
        # unescaped, so a quote or space would cut the link short.
        anchor = re.sub(r"[^\w.\-]", "-", name)
        if self.objtype == "module":
            anchor = "module-" + anchor
        signode["ids"].append(anchor)
        self.state.document.note_explicit_target(signode)
        domain: ZigDomain = self.env.domains["zig"]  # type: ignore[assignment]
        domain.note_object(name, self.objtype, anchor, location=signode)
        if "no-index-entry" not in self.options:
            label = LABELS[self.objtype]
            self.indexnode["entries"].append(("single", f"{name} (Zig {label})", anchor, "", None))

    def _object_hierarchy_parts(self, sig_node: desc_signature) -> tuple[str, ...]:
        if self.objtype == "module" or "fullname" not in sig_node:
            return ()
        return tuple(sig_node["fullname"].split("."))

    def _toc_entry_name(self, sig_node: desc_signature) -> str:
        parts = sig_node.get("_toc_parts")
        if not parts:
            return ""
        parens = "()" if self.objtype == "function" and self.config.add_function_parentheses else ""
        show = self.config.toc_object_entries_show_parents
        if show == "all":
            return ".".join(parts) + parens
        return parts[-1] + parens


class ZigXRefRole(XRefRole):
    def process_link(
        self, env: BuildEnvironment, refnode: Element, has_explicit_title: bool, title: str, target: str
    ) -> tuple[str, str]:
        target = target.lstrip("~")
        if not has_explicit_title:
            title = title.lstrip(".")
            if title.startswith("~"):
                title = title[1:].rsplit(".", 1)[-1]
        return title, target.lstrip(".")


class ZigAutodocRole(SphinxRole):
    """``:zig:autodoc:`zig_common.proc```, or ``:zig:autodoc:`text </>``` for the front page."""

    def run(self) -> tuple[list[Node], list[nodes.system_message]]:
        explicit, title, target = split_explicit_title(self.text)
        target = target.strip()
        href = autodoc_href(self.env, target)
        if href is None:
            return [nodes.Text(title)], []
        return [link(title if explicit else (target or "Zig autodoc"), href, "zig-autodoc-link")], []


class ZigDomain(Domain):
    name = "zig"
    label = "Zig"
    object_types: ClassVar[dict[str, ObjType]] = {
        "module": ObjType("module", "mod", "obj"),
        "type": ObjType("type", "type", "obj"),
        "errorset": ObjType("error set", "err", "type", "obj"),
        "function": ObjType("function", "fn", "func", "obj"),
        "constant": ObjType("constant", "const", "obj"),
        "variable": ObjType("variable", "var", "obj"),
        "field": ObjType("field", "field", "obj"),
        "error": ObjType("error", "err", "obj"),
    }
    directives: ClassVar[dict[str, type[ObjectDescription]]] = {k: ZigObject for k in object_types}
    roles: ClassVar[dict[str, Any]] = {
        **{r: ZigXRefRole() for r in ("mod", "type", "err", "fn", "func", "const", "var", "field", "obj")},
        "autodoc": ZigAutodocRole(),
    }
    initial_data: ClassVar[dict[str, Any]] = {"objects": {}}
    data_version = 1

    @property
    def objects(self) -> dict[str, tuple[str, str, str]]:
        """Full name -> (docname, anchor, object type)."""
        return self.data.setdefault("objects", {})

    def note_object(self, fqn: str, objtype: str, anchor: str, location: Any = None) -> None:
        if fqn in self.objects:
            other = self.objects[fqn][0]
            logger.warning("duplicate Zig object %s, also in %s", fqn, other, location=location, type="zig", subtype="duplicate")
        self.objects[fqn] = (self.env.docname, anchor, objtype)

    def clear_doc(self, docname: str) -> None:
        for fqn, (doc, _anchor, _objtype) in list(self.objects.items()):
            if doc == docname:
                del self.objects[fqn]

    def merge_domaindata(self, docnames: Iterable[str], otherdata: dict[str, Any]) -> None:
        for fqn, entry in otherdata["objects"].items():
            if entry[0] in docnames:
                self.objects[fqn] = entry

    def find(self, target: str, objtypes: Iterable[str] | None) -> list[tuple[str, tuple[str, str, str]]]:
        wanted = set(objtypes) if objtypes is not None else None

        def ok(entry: tuple[str, str, str]) -> bool:
            return wanted is None or entry[2] in wanted

        entry = self.objects.get(target)
        if entry is not None and ok(entry):
            return [(target, entry)]
        suffix = "." + target
        return [(fqn, e) for fqn, e in self.objects.items() if fqn.endswith(suffix) and ok(e)]

    def resolve_xref(
        self,
        env: BuildEnvironment,
        fromdocname: str,
        builder: Builder,
        typ: str,
        target: str,
        node: pending_xref,
        contnode: Element,
    ) -> nodes.reference | None:
        matches = self.find(target, self.objtypes_for_role(typ))
        if not matches:
            return None
        if len(matches) > 1:
            logger.warning(
                "more than one Zig object matches %r: %s",
                target,
                ", ".join(sorted(m[0] for m in matches)),
                location=node,
                type="ref",
                subtype="zig",
            )
        fqn, (docname, anchor, _objtype) = matches[0]
        return make_refnode(builder, fromdocname, docname, anchor, contnode, fqn)

    def resolve_any_xref(
        self,
        env: BuildEnvironment,
        fromdocname: str,
        builder: Builder,
        target: str,
        node: pending_xref,
        contnode: Element,
    ) -> list[tuple[str, nodes.reference]]:
        results = []
        for fqn, (docname, anchor, objtype) in self.find(target, None):
            role = self.role_for_objtype(objtype) or "obj"
            results.append((f"zig:{role}", make_refnode(builder, fromdocname, docname, anchor, contnode, fqn)))
        return results

    def get_objects(self) -> Iterable[tuple[str, str, str, str, str, int]]:
        for fqn, (docname, anchor, objtype) in self.objects.items():
            yield fqn, fqn, objtype, docname, anchor, 1

    def get_full_qualified_name(self, node: Element) -> str | None:
        return node.get("reftarget")


def setup(app: Sphinx) -> dict[str, Any]:
    app.add_config_value("zig_autodoc_root", "", "env", types=frozenset({str}))
    app.add_domain(ZigDomain)
    return {"version": "1", "env_version": 1, "parallel_read_safe": True, "parallel_write_safe": True}
