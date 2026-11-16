#!/usr/bin/env python3
"""Check a built site: internal links, anchors and forbidden names.

    python docs/tools/check_site.py docs/build/html [--sources docs/orgmode]
        [--forbid REGEX]... [--no-default-forbid] [--exempt PAGE]...

Every relative href and src in every HTML page must name a file in the site,
and a #fragment on a page Sphinx made must name an id on that page. Under
api/, the Zig autodoc site, only files are checked: its anchors are made by
script. External links are lychee's job (pixi task linkcheck).

A page may not link to a generated .rst file (the edit links go to the Org
sources), and no page's text or link targets, and no Org source, may carry
a forbidden pattern: by default the names and paths of one real site, as
the pages describe a neutral example site, and links to AI chat services.
--exempt names a built page, such as changelog.html, that records history:
its text and link targets are not checked for forbidden names, but its
links must still resolve.

Exit status: 0 when clean, 1 when anything is wrong, 2 on a usage error.
"""

import argparse
import html.parser
import os
import re
import sys
import urllib.parse

# The repositories' CI greps the whole tree for these names, this file
# included, so each keeps one letter in a class: the pattern matches the
# name, and its own text does not.
DEFAULT_FORBID = [
    r"snelli[u]s",
    r"sne[l]-",
    r"surf\.nl",
    r"surfsara",
    r"/gp[f]s/",
    r"/project[s]/0",
    r"rg\.terra",
    r"scratch-shar[e]d",
    r"scratch-nod[e]",
    r"eblocalinstal[l]",
    r"chatgpt\.com",
    r"claude\.ai",
    r"perplexity\.ai",
]

SCRIPTED_ANCHORS = ("api/",)


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.text = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        for key in ("id", "name"):
            if attrs.get(key) and (key == "id" or tag == "a"):
                self.ids.add(attrs[key])
        for key in ("href", "src"):
            value = attrs.get(key)
            if value is not None and not (tag == "link" and attrs.get("rel") in ("preconnect", "dns-prefetch")):
                self.links.append((value, self.getpos()[0]))
        if tag in ("script", "style"):
            self._skip += 1

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self._skip:
            self._skip -= 1

    def handle_data(self, data):
        if not self._skip:
            self.text.append(data)


def parse(path):
    page = Page()
    with open(path, encoding="utf-8", errors="replace") as handle:
        page.feed(handle.read())
    return page


def check_site(root, forbid, exempt=()):
    errors = []
    pages = {}
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".html"):
                path = os.path.join(dirpath, name)
                pages[os.path.relpath(path, root)] = parse(path)

    for rel, page in sorted(pages.items()):
        scripted = rel.startswith(SCRIPTED_ANCHORS)
        for href, line in page.links:
            where = f"{rel}:{line}"
            if re.search(r"\.rst(?:[?#]|$)", href.split("?")[0]):
                errors.append(f"{where}: link to a generated .rst file: {href}")
            parts = urllib.parse.urlsplit(href)
            if parts.scheme or href.startswith("//") or href.startswith(("mailto:", "data:", "javascript:")):
                continue
            target_rel = rel if not parts.path else os.path.normpath(
                os.path.join(os.path.dirname(rel), urllib.parse.unquote(parts.path))
            )
            if target_rel.startswith(".."):
                errors.append(f"{where}: link leaves the site: {href}")
                continue
            target = os.path.join(root, target_rel)
            if os.path.isdir(target):
                target_rel = os.path.join(target_rel, "index.html")
                target = os.path.join(root, target_rel)
            if not os.path.isfile(target):
                errors.append(f"{where}: no such file: {href}")
                continue
            fragment = urllib.parse.unquote(parts.fragment)
            if not fragment or scripted or target_rel.startswith(SCRIPTED_ANCHORS):
                continue
            target_page = pages.get(os.path.normpath(target_rel))
            if target_page is not None and fragment not in target_page.ids:
                errors.append(f"{where}: no anchor #{fragment} in {target_rel}")
        if not scripted and rel not in exempt:
            text = " ".join(page.text)
            for pattern in forbid:
                found = pattern.search(text)
                if found:
                    errors.append(f"{rel}: forbidden text {found.group(0)!r} (pattern {pattern.pattern})")
                for href, line in page.links:
                    if pattern.search(href):
                        errors.append(f"{rel}:{line}: forbidden link {href} (pattern {pattern.pattern})")
    return errors, len(pages)


def check_sources(roots, forbid):
    errors = []
    for top in roots:
        for dirpath, _dirs, files in os.walk(top):
            for name in sorted(files):
                if not name.endswith((".org", ".md", ".rst", ".py", ".el")):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8", errors="replace") as handle:
                    for number, line in enumerate(handle, 1):
                        for pattern in forbid:
                            found = pattern.search(line)
                            if found:
                                errors.append(f"{path}:{number}: forbidden text {found.group(0)!r}")
    return errors


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("site", help="the built HTML directory")
    parser.add_argument("--sources", action="append", default=[], help="a source tree to scan for forbidden text")
    parser.add_argument("--forbid", action="append", default=[], help="another forbidden regular expression")
    parser.add_argument("--no-default-forbid", action="store_true", help="drop the default forbidden patterns")
    parser.add_argument("--exempt", action="append", default=[], metavar="PAGE",
                        help="a built page, relative to the site, whose text is not checked for forbidden names")
    args = parser.parse_args(argv)
    if not os.path.isfile(os.path.join(args.site, "index.html")):
        print(f"check_site: no index.html in {args.site}", file=sys.stderr)
        return 2
    patterns = ([] if args.no_default_forbid else DEFAULT_FORBID) + args.forbid
    forbid = [re.compile(p, re.I) for p in patterns]
    errors, count = check_site(args.site, forbid, set(args.exempt))
    errors += check_sources(args.sources, forbid)
    for error in errors:
        print(error)
    print(f"check_site: {count} pages, {len(errors)} problem(s)", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
