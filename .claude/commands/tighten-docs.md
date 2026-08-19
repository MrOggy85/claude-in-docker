---
description: Cut a doc to its load-bearing facts, proving no fact was lost
argument-hint: "[file|glob]   (default: markdown changed vs master)"
allowed-tools: Read, Edit, Glob, Grep, Bash(git diff:*), Bash(git status:*), Bash(git stash:*), Bash(python3:*)
---

Run the `## Docs` pass from `CLAUDE.md` over a set of markdown files, then prove
mechanically that only prose went. `docs/publishing-ports.md` at f6b85b1 is the
target density.

## 1. Scope

Use `$ARGUMENTS` if given. Otherwise take the markdown files this branch touches:

```bash
git diff --name-only master...HEAD -- '*.md'
git status --short -- '*.md'
```

If both are empty, stop and say so. Do not sweep all of `docs/` unasked — that is
a 24-file rewrite.

## 2. Inventory each file BEFORE editing

Facts in these docs live in code spans, tables, code blocks and links. Capture
them first so the check afterwards is a comparison, not a judgement:

```bash
python3 - "$FILE" <<'PY'
import json, re, sys
t = open(sys.argv[1]).read()
blocks = re.findall(r'^```.*?^```', t, re.S | re.M)
body = re.sub(r'^```.*?^```', '', t, flags=re.S | re.M)
print(json.dumps({
  'headings': re.findall(r'^#{1,6} .*', body, re.M),
  'rows':     [l for l in body.splitlines() if l.strip().startswith('|')],
  'blocks':   blocks,
  'links':    re.findall(r'\]\(([^)]+)\)', body),
  'spans':    sorted(set(re.findall(r'`([^`\n]+)`', body))),
  'words':    len(body.split()),
}, indent=1))
PY
```

## 3. Edit

Cut only what `CLAUDE.md` `## Docs` lists, and rewrap to the width that file
already uses. Then cut 15% more words, or say why the file was already at density.

## 4. Prove it

Re-run the inventory and diff the two.

- **Hard gate — must be byte-identical:** `headings`, `rows`, `blocks`. Other
  docs deep-link to heading anchors (`attack-vectors.md` especially), tables are
  the reference matter, and a changed code block is a changed instruction. Any
  delta is a bug in your edit: restore it.
- **`links`:** unchanged set, and every relative target must still resolve on disk.
- **`spans`:** a dropped span is allowed only when the doc it links to still
  documents that identifier — the `index.md` case, where a one-line summary drops
  a flag the guide itself covers. List every dropped span with that justification,
  or restore it.
- **`words`:** report before -> after per file, and the total.

## 5. Report

Per file: word delta and any justified span drops. Then the aggregate, in the
shape of f6b85b1: `N files, X -> Y words, no fact removed`. If you cannot make
that claim honestly, say which file broke it and why — an unverified claim is
worse than a smaller cut.
