#!/usr/bin/env python3
"""Validate an Open Knowledge Format (OKF v0.1) bundle.

Implements the OKF v0.1 conformance rules (SPEC.md section 9):
  1. Every non-reserved .md file has a parseable YAML frontmatter block.
  2. Every frontmatter block has a non-empty `type` field.
  3. Reserved files (index.md, log.md) follow their prescribed structure:
     - index.md carries no frontmatter, except a bundle-root index.md MAY
       carry only `okf_version` (SPEC sections 6 and 11).
     - log.md date headings use ISO `## YYYY-MM-DD` form (SPEC section 7).

Dependency-free (no PyYAML): frontmatter is parsed with a minimal line reader,
which is sufficient for the flat key/value blocks OKF concepts use.

Usage:  python3 scripts/okf-validate.py [bundle_dir]   (default: docs)
Exit 0 if conformant, 1 otherwise.
"""
import os
import re
import sys

RESERVED = {"index.md", "log.md"}


def split_frontmatter(text):
    """Return (frontmatter_dict, ok, error). ok=False means no/invalid block."""
    if not text.startswith("---"):
        return {}, False, "no frontmatter fence at start of file"
    lines = text.splitlines()
    if lines[0].strip() != "---":
        return {}, False, "opening '---' must be alone on line 1"
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, False, "unterminated frontmatter block (no closing '---')"
    fm = {}
    for ln in lines[1:end]:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", ln)
        if not m:
            return {}, False, f"unparseable frontmatter line: {ln!r}"
        fm[m.group(1)] = m.group(2).strip()
    return fm, True, None


def validate(bundle):
    problems = []
    md_files = []
    for root, _dirs, files in os.walk(bundle):
        for f in files:
            if f.endswith(".md"):
                md_files.append(os.path.join(root, f))
    if not md_files:
        problems.append(f"{bundle}: no markdown files found")

    for path in sorted(md_files):
        rel = os.path.relpath(path, bundle)
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()

        if name in RESERVED:
            if name == "index.md":
                is_root = os.path.dirname(path) == os.path.normpath(bundle)
                if text.lstrip().startswith("---"):
                    fm, ok, err = split_frontmatter(text.lstrip())
                    if not ok:
                        problems.append(f"{rel}: {err}")
                    elif not is_root:
                        problems.append(f"{rel}: only a bundle-root index.md may carry frontmatter")
                    elif set(fm) - {"okf_version"}:
                        problems.append(f"{rel}: index frontmatter may contain only okf_version, found {sorted(fm)}")
            elif name == "log.md":
                heads = [ln for ln in text.splitlines() if ln.startswith("## ")]
                bad = [h for h in heads if not re.match(r"^## \d{4}-\d{2}-\d{2}\s*$", h)]
                for h in bad:
                    problems.append(f"{rel}: log date heading not ISO YYYY-MM-DD: {h!r}")
            continue

        # non-reserved concept
        fm, ok, err = split_frontmatter(text)
        if not ok:
            problems.append(f"{rel}: {err}")
            continue
        if not fm.get("type"):
            problems.append(f"{rel}: missing or empty required 'type' field")

    return problems, len(md_files)


def main():
    bundle = sys.argv[1] if len(sys.argv) > 1 else "docs"
    if not os.path.isdir(bundle):
        print(f"not a directory: {bundle}", file=sys.stderr)
        return 2
    problems, n = validate(bundle)
    if problems:
        print(f"OKF v0.1: NON-CONFORMANT ({len(problems)} issue(s)) in '{bundle}/':")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"OKF v0.1: CONFORMANT — {n} markdown file(s) in '{bundle}/' pass all checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
