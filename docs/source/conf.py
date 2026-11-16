"""Sphinx configuration for the zig-common documentation.

The pages are Org files under docs/orgmode/, exported here as reStructuredText
by docs/export.el. The API reference under reference/api/ is generated from
the code. Neither is committed: `pixi run -e docs docbld` makes both.
"""

import os
import re
import sys

from docutils import nodes

_here = os.path.dirname(os.path.abspath(__file__))
_repo = os.path.abspath(os.path.join(_here, "..", ".."))
sys.path.insert(0, os.path.join(_here, "_ext"))

project = "zig-common"
author = "stackhands developers"
copyright = "stackhands developers"


def _release():
    """The version the build files declare: build.zig.zon, pyproject.toml or Cargo.toml."""
    for name, pattern in (
        ("build.zig.zon", r'^\s*\.version\s*=\s*"([^"]+)"'),
        ("pyproject.toml", r'^version\s*=\s*"([^"]+)"'),
        ("Cargo.toml", r'^version\s*=\s*"([^"]+)"'),
    ):
        path = os.path.join(_repo, name)
        if os.path.isfile(path):
            found = re.search(pattern, open(path, encoding="utf-8").read(), re.M)
            if found:
                return found.group(1)
    return ""


release = version = _release()

extensions = [
    "myst_parser",
    "sphinx.ext.intersphinx",
    "sphinx_copybutton",
    "sphinx_design",
    "sphinx_sitemap",
    "zig_domain",
]

# Generated API pages are MyST Markdown, as doc comments are Markdown; the
# exported Org pages are reStructuredText.
source_suffix = {".rst": "restructuredtext", ".md": "markdown"}
myst_enable_extensions = ["colon_fence", "deflist", "fieldlist"]
exclude_patterns = []
templates_path = ["_templates"]

# Every cross-reference must resolve: sphinx-build runs with -W -n.
nitpicky = True
nitpick_ignore = []
manpages_url = "https://man7.org/linux/man-pages/man{section}/{page}.{section}.html"
# Doc comments and docstrings name flags in plain text: --strict stays two
# hyphens.
smartquotes_action = "qe"

# -- API reference -----------------------------------------------------------
# Zig: docs/tools/zig_api.zig writes reference/api/zig/ (pixi task mkapi), and
# `zig build docs` puts the autodoc site at api/ (pixi task autodoc).
zig_autodoc_root = "api/"

# Python: sphinx-autoapi reads the packages listed here, without importing
# them, into reference/api/python/.
PYTHON_PACKAGES = []
if PYTHON_PACKAGES:
    extensions.append("autoapi.extension")
    autoapi_type = "python"
    autoapi_dirs = [os.path.join(_repo, p) for p in PYTHON_PACKAGES]
    autoapi_root = "reference/api/python"
    autoapi_add_toctree_entry = False
    autoapi_keep_files = False
    autoapi_member_order = "groupwise"
    # undoc-members: a module or class without a docstring is still listed,
    # so the reference is complete and the gap shows.
    autoapi_options = [
        "members",
        "undoc-members",
        "show-inheritance",
        "show-module-summary",
        "special-members",
        "imported-members",
    ]
    autoapi_ignore = ["*/tests/*", "*/test_*.py", "*/conftest.py"]

# Rust: sphinx-rustdocgen reads each crate listed here (crate name: its
# directory) into reference/api/rust/<crate>/, for sphinxcontrib-rust.
RUST_CRATES = {}
if RUST_CRATES:
    extensions.append("sphinxcontrib_rust")
    rust_crates = {name: os.path.join(_repo, path) for name, path in RUST_CRATES.items()}
    rust_doc_dir = os.path.join(_here, "reference", "api", "rust")
    # Doc comments are Markdown, read by myst_parser.
    rust_rustdoc_fmt = "md"
    rust_generate_mode = "always"
    # A rustdoc link to an item named like its module ([`gap`] in gap) also
    # matches that module's page; MyST links the page, which lists the item.
    suppress_warnings = ["myst.xref_ambiguous"]
    # A type from std, core or another crate has no page here; a name in
    # these crates that does not resolve still fails the build.
    nitpick_ignore_regex = [
        (r"rust:.*", r"(?!(?:%s)(?:::|$)).*" % "|".join(RUST_CRATES)),
        ("myst", r"\w+(?:::\w+)+"),
    ]

# -- Links to other sites ----------------------------------------------------
# A link to another stackhands site resolves through that site's objects.inv,
# so a page or API name that does not exist there fails the build. A local
# build keeps the inventories it fetched for 30 days and works offline in
# that time; CI starts clean and always fetches them.
# stackhands-intersphinx:begin (written by docs-plan/template/apply.py)
intersphinx_mapping = {
    "eb-staged-rebuild": ("https://stackhands.github.io/eb-staged-rebuild/", None),
    "eessi-arch-guard": ("https://stackhands.github.io/eessi-arch-guard/", None),
    "eb-local": ("https://stackhands.github.io/eb-local/", None),
    "eb-keep-logs": ("https://stackhands.github.io/eb-keep-logs/", None),
}
# stackhands-intersphinx:end
intersphinx_mapping["python"] = ("https://docs.python.org/3", None)
intersphinx_cache_limit = 30
intersphinx_timeout = 30

# -- HTML ----------------------------------------------------------------------
html_theme = "shibuya"
html_title = "zig-common"
html_baseurl = "https://stackhands.github.io/zig-common/"
html_static_path = ["_static"]
html_css_files = ["stackhands.css"]
# The logos come from stackhands/.github branding (apply.py copies them).
_logos = {
    name: "_static/" + name
    for name in ("favicon.svg", "logo-light.svg", "logo-dark.svg")
    if os.path.isfile(os.path.join(_here, "_static", name))
}
html_favicon = _logos.get("favicon.svg")
html_copy_source = False
html_show_sourcelink = False
sitemap_url_scheme = "{link}"

html_context = {
    "source_type": "github",
    "source_user": "stackhands",
    "source_repo": "zig-common",
    "source_version": "main",
    "source_docs_path": "/docs/orgmode/",
}

html_theme_options = {
    "github_url": "https://github.com/stackhands/zig-common",
    "accent_color": "teal",
    "dark_code": True,
    # Its "Copy page" menu links chat services, which check_site.py rejects.
    "show_ai_links": False,
    "globaltoc_expand_depth": 1,
    "nav_links": [
        {"title": "Tutorial", "url": "tutorials/index"},
        {"title": "How-to", "url": "howto/index"},
        {"title": "Explanation", "url": "explanation/index"},
        {"title": "Reference", "url": "reference/index"},
        # stackhands:begin (generated by stackhands/.github branding/sync.py)
        {
            "title": "stackhands",
            "children": [
                {
                    "title": "eb-stack",
                    "url": "https://eb-stack.rgoswami.me/",
                    "summary": "Solve, shard and plan an EasyBuild build list; admit builds under a scratch inode budget",
                },
                {
                    "title": "eb-pipeline",
                    "url": "https://github.com/stackhands/eb-pipeline#readme",
                    "summary": "Drive an EasyBuild pipeline from one per-site TOML file, calling the other tools as subprocesses",
                },
                {
                    "title": "eb-staged-rebuild",
                    "url": "https://stackhands.github.io/eb-staged-rebuild/",
                    "summary": "Rebuild an installation in a staged tree and swap it in, so running jobs keep their paths",
                },
                {
                    "title": "eessi-arch-guard",
                    "url": "https://stackhands.github.io/eessi-arch-guard/",
                    "summary": "Reload EESSI in a Slurm task that inherited it for another CPU or GPU",
                },
                {
                    "title": "eb-local",
                    "url": "https://stackhands.github.io/eb-local/",
                    "summary": "Install software with EasyBuild on top of EESSI into a directory a user or project owns",
                },
                {
                    "title": "eb-keep-logs",
                    "url": "https://stackhands.github.io/eb-keep-logs/",
                    "summary": "Keep a failed build's EasyBuild log and command output; rotate a pipeline's log tree",
                },
                {
                    "title": "rfc9162",
                    "url": "https://stackhands.github.io/rfc9162/",
                    "summary": "Append-only Merkle logs hashed as RFC 9162, with tiled storage and signed checkpoints",
                },
            ],
        },
        # stackhands:end
    ],
}
if "logo-light.svg" in _logos and "logo-dark.svg" in _logos:
    html_theme_options["light_logo"] = _logos["logo-light.svg"]
    html_theme_options["dark_logo"] = _logos["logo-dark.svg"]

html_sidebars = {
    "**": [
        "sidebars/localtoc.html",
        "sidebars/repo-stats.html",
        "sidebars/edit-this-page.html",
    ],
}


def _edit_link(app, pagename, templatename, context, doctree):
    """Point "edit this page" at the Org source; generated pages have none."""
    if pagename.startswith("reference/api/"):
        context["page_source_suffix"] = None
    else:
        context["page_source_suffix"] = ".org"


def _unlink_rust_paths(app, doctree, docname):
    """A rustdoc link to an item outside these crates stays as code, unlinked."""
    if not docname.startswith("reference/api/rust/"):
        return
    for ref in list(doctree.findall(nodes.reference)):
        if re.fullmatch(r"\w+(?:::\w+)+", ref.get("refid", "")):
            ref.replace_self(ref.children)


def setup(app):
    app.connect("html-page-context", _edit_link)
    if RUST_CRATES:
        app.connect("doctree-resolved", _unlink_rust_paths)
    if "local_setup" in globals():
        globals()["local_setup"](app)


# -- This repository -----------------------------------------------------------
# apply.py rewrites everything above and keeps what is between these markers:
# the place for settings only this repository has, such as the Rust crates
# for sphinxcontrib-rust or a nitpick_ignore entry. Event hooks go in a
# function local_setup(app), which setup() calls.
# local:begin
# local:end
