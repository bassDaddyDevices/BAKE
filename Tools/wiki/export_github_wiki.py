#!/usr/bin/env python3
"""Exports BAKE's wiki (BAKE_DOCS/wiki) as a GitHub wiki: flat pages, GitHub links, a sidebar.

    python3 Tools/wiki/export_github_wiki.py BAKE_DOCS/wiki /tmp/bake-github-wiki

Only the wiki is public; the other knowledge-base documents (decisions, PRD, roadmap, plans,
reports) are not. Links to them keep their text and lose the link, and anything between
`<!-- internal -->` and `<!-- /internal -->` is left out. Pages that are internal process
(the wiki log, the old contributor contract, requirements coverage, the node catalog's design record)
are left out; CONTRIBUTING.md
in the repository replaces the contributor guides. The output folder's .md files are replaced; its
.git (the wiki repository) is left alone.
"""
import os, re, sys

# Internal: the wiki log, the old contributor contract and coverage, and the node catalog's design record
# (its history and review notes); the generated node pages are the public catalog.
SKIP = {"log.md", "guides/node-development.md", "guides/open-node-specs.md", "guides/requirements-coverage.md",
        "modules/node-catalog.md"}
SECTIONS = [("Concepts", "concepts"), ("Guides", "guides"), ("Architecture", "architecture"),
            ("Modules", "modules"), ("Flows", "flows")]
LINK = re.compile(r"(!?)\[([^\]]*)\]\(([^)\s]+)(\s+\"[^\"]*\")?\)")


def split_frontmatter(text):
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end >= 0:
            head = text[4:end]
            body = text[end + 4:].lstrip("\n")
            title = re.search(r"^title:\s*\"?(.*?)\"?\s*$", head, re.M)
            return (title.group(1) if title else None), body
    return None, text


def page_name(title):
    return re.sub(r"[^A-Za-z0-9]+", "-", title).strip("-")


def main(source, out):
    pages = {}  # wiki-relative path → (github page name, title, body)
    for root, _, files in os.walk(source):
        for name in files:
            if not name.endswith(".md"):
                continue
            path = os.path.relpath(os.path.join(root, name), source)
            if path in SKIP or path.startswith("."):
                continue
            title, body = split_frontmatter(open(os.path.join(root, name)).read())
            title = title or os.path.splitext(name)[0]
            github = "Home" if path == "OVERVIEW.md" else page_name(title)
            pages[path] = (github, title, body)
    names = [p[0] for p in pages.values()]
    duplicates = {n for n in names if names.count(n) > 1}
    if duplicates:
        sys.exit(f"duplicate page names: {sorted(duplicates)}")

    def rewrite(path, body):
        folder = os.path.dirname(path)
        # Anything between <!-- internal --> and <!-- /internal --> is for the knowledge base only.
        body = re.sub(r"<!-- internal -->.*?<!-- /internal -->\n?", "", body, flags=re.S)

        def replace(match):
            image, text, target, title = match.groups()
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                return match.group(0)
            file, _, anchor = target.partition("#")
            resolved = os.path.normpath(os.path.join(folder, file))
            if resolved in pages:
                return f"[{text}]({pages[resolved][0]}{'#' + anchor if anchor else ''})"
            return text  # not public: keep the words, drop the link

        return LINK.sub(replace, body)

    os.makedirs(out, exist_ok=True)
    for old in os.listdir(out):
        if old.endswith(".md"):
            os.remove(os.path.join(out, old))
    for path, (github, title, body) in pages.items():
        body = rewrite(path, body)
        # GitHub shows the page name as its title; drop a first heading that only repeats it.
        lines = body.split("\n")
        if lines and lines[0].lstrip("# ").strip() == title and lines[0].startswith("# "):
            body = "\n".join(lines[1:]).lstrip("\n")
        open(os.path.join(out, github + ".md"), "w").write(body.rstrip() + "\n")

    sidebar = ["**[Home](Home)**", "", "**[All nodes](All-nodes)**", "", "[How batches work](How-batches-work)", ""]
    for heading, folder in SECTIONS:
        entries = sorted((title, github) for path, (github, title, _) in pages.items()
                         if path.startswith(folder + "/") and github != "How-batches-work")
        if entries:
            sidebar += [f"**{heading}**", ""] + [f"- [{t}]({g})" for t, g in entries] + [""]
    open(os.path.join(out, "_Sidebar.md"), "w").write("\n".join(sidebar))
    print(f"{len(pages)} pages and a sidebar in {out}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
