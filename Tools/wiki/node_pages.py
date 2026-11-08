#!/usr/bin/env python3
"""Builds one wiki page per BAKE node, plus an index, from the code's node catalog.

    BAKE_DUMP_CATALOG=/tmp/bake-catalog.json swift test --package-path BakeCore --filter CatalogDumpTests
    python3 Tools/wiki/node_pages.py /tmp/bake-catalog.json BAKE_DOCS/wiki/nodes

Pins, controls, ranges, defaults and what's modulatable come from the catalog; the plain-language
"what it does" and "try" lines come from node-descriptions.json next to this script. The output
folder gets one .md per node plus index.md, each with its frontmatter; pages for nodes that no
longer exist are removed. Export the wiki for GitHub with export_github_wiki.py.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def slug(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")


def option_title(raw, shown):
    """The card's title, unless it's just the camelCase id capitalized ("trueStereo" → "Truestereo")."""
    if re.search(r"[a-z][A-Z]", raw) and shown == raw[:1].upper() + raw[1:].lower():
        words = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", raw).split()
        return " ".join(w[:1].upper() + w[1:] for w in words)
    return shown


def number(value):
    if value == int(value):
        text = str(int(value))
        sign, digits = ("-", text[1:]) if text.startswith("-") else ("", text)
        if len(digits) > 4:
            digits = f"{int(digits):,}".replace(",", " ")
        return sign + digits
    return f"{value:.3f}".rstrip("0").rstrip(".")


def unit(text, value):
    return f"{value} {text}" if text else value


def pin_label(label):
    return {"Ir": "IR", "Sidechain": "Sidechain"}.get(label, label)


def control_rows(parameters, by_id):
    rows = []
    for p in parameters:
        if p["type"] == "number":
            span = f"{number(p['min'])} to {number(p['max'])}"
            values, default = unit(p["unit"], span), unit(p["unit"], number(p["default"]))
        elif p["type"] == "choice":
            titles = [option_title(r, t) for r, t in zip(p["options"], p["optionTitles"])]
            values, default = " · ".join(titles), option_title(p["default"], p["defaultTitle"])
        else:
            values, default = "text", f"`{p['default']}`" if p["default"] else "(empty)"
        notes = []
        if p.get("shownWhen"):
            other = by_id.get(p["shownWhen"]["parameter"])
            name = other["name"] if other else p["shownWhen"]["parameter"]
            titles = [option_title(r, t) for r, t in zip(p["shownWhen"]["values"], p["shownWhen"]["titles"])]
            notes.append(f"when {name} is {' or '.join(titles)}")
        modulatable = "✓" if p["modulatable"] else ""
        rows.append(f"| {p['name']} | {values} | {default} | {modulatable} | {'; '.join(notes)} |")
    return rows


def page(node, description, tip):
    by_id = {p["id"]: p for p in node["parameters"]}
    where = node["group"] + (f" › {node['subgroup']}" if node.get("subgroup") else "")
    ins = [f"{pin_label(p['label'])} ({p['signal']}{', required' if p['required'] else ''})" for p in node["pins"] if p["direction"] == "in"]
    outs = [f"{pin_label(p['label'])} ({p['signal']})" for p in node["pins"] if p["direction"] == "out"]
    if node.get("repeated"):
        note = " — the number of these follows its setting"
        if any(p["direction"] == "out" for p in node["pins"]) and not outs:
            outs.append("Outputs" + note)
    lines = [f"# {node['title']}", "", description, "",
             f"**Add Node:** {where}  ", f"**Inputs:** {', '.join(ins) or 'none'}  ", f"**Outputs:** {', '.join(outs) or 'none'}", ""]
    header = ["| Control | Range / options | Default | Modulatable | Shown |", "|---|---|---|---|---|"]
    page1 = [p for p in node["parameters"] if p["role"] == "page1"]
    page2 = [p for p in node["parameters"] if p["role"] == "page2"]
    if page1:
        lines += ["## On the card", ""] + header + control_rows(page1, by_id) + [""]
    if page2:
        lines += ["## Settings (Page 2)", ""] + header + control_rows(page2, by_id) + [""]
    if not page1 and not page2:
        lines += ["No controls.", ""]
    if any(p["modulatable"] for p in node["parameters"]):
        lines += ["Controls marked ✓ can be modulated: tick them on Page 2 and a pin appears for each.", ""]
    if tip:
        lines += ["## Try", "", tip, ""]
    lines += ["## See also", "", "- [All nodes](index.md)"]
    if node["group"] == "Batch":
        lines.append("- [How batches work](../concepts/how-batches-work.md)")
    lines.append("")
    frontmatter = {
        "title": node["title"], "description": description.split(". ")[0].rstrip(".") + ".",
        "type": "node", "tags": ["wiki", "node", slug(node["group"])],
    }
    return frontmatter, "\n".join(lines)


def frontmatter_text(values):
    lines = ["---"]
    for key, value in values.items():
        if isinstance(value, list):
            lines.append(f"{key}:")
            lines += [f"  - {item}" for item in value]
        else:
            lines.append(f"{key}: {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines + ["---", ""])


def main(catalog_path, out_dir):
    catalog = json.load(open(catalog_path))
    descriptions = json.load(open(os.path.join(HERE, "node-descriptions.json")))
    os.makedirs(out_dir, exist_ok=True)
    pages = []
    for node in catalog:
        description, tip = descriptions[node["kind"]]
        frontmatter, body = page(node, description, tip)
        pages.append({"path": f"wiki/nodes/{slug(node['title'])}", "frontmatter": frontmatter, "content": body})
    # The index: every node by Add Node group, one line each.
    index = ["# All nodes", "", "Every node in BAKE's Add Node menu, by group, with what it does in a line. Each name opens its own page: inputs, outputs, every control with its range and default, and what can be modulated.", "",
             "New to batches? [How batches work](../concepts/how-batches-work.md) explains passes, routers and gathers.", ""]
    group = None
    for node in catalog:
        heading = node["group"] + (f" › {node['subgroup']}" if node.get("subgroup") else "")
        if heading != group:
            group = heading
            index += ["", f"## {heading}", "", "| Node | What it does |", "|---|---|"]
        index.append(f"| [{node['title']}]({slug(node['title'])}.md) | {descriptions[node['kind']][0]} |")
    index += ["", f"{len(catalog)} nodes. Pages are generated from the code (`Tools/wiki/node_pages.py`), so they match what the app shows.", ""]
    pages.insert(0, {"path": "wiki/nodes/index", "frontmatter": {
        "title": "All nodes", "description": "Every BAKE node by Add Node group, one line each, linking to its own page.",
        "type": "index", "tags": ["wiki", "nodes", "index"]}, "content": "\n".join(index)})
    names = {p["path"].split("/")[-1] + ".md" for p in pages}
    for old in os.listdir(out_dir):
        if old.endswith(".md") and old not in names:
            os.remove(os.path.join(out_dir, old))
    for p in pages:
        with open(os.path.join(out_dir, p["path"].split("/")[-1] + ".md"), "w") as f:
            f.write(frontmatter_text(p["frontmatter"]) + p["content"])
    print(f"{len(pages)} pages in {out_dir}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
