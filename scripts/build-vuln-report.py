#!/usr/bin/env python3
"""Build a self-contained HTML page from image SBOM scans and Grype reports.

Reads scan-summary.json and <id>.cdx.json from --scans, <id>.grype.json from
--grype, and writes index.html plus downloadable copies of the SBOMs to
--output. No network requests; no external scripts, fonts or styles.
"""
import argparse
import collections
import datetime as dt
import html
import json
import os
from pathlib import Path
import shutil

LEVELS = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]
COLORS = {"Critical": "#a52e35", "High": "#c25a00", "Medium": "#845600", "Low": "#1a5cab", "Negligible": "#596a80", "Unknown": "#596a80"}

CSS = """:root{--ink:#18283d;--muted:#596a80;--line:#dce4ee;--paper:#fff;--canvas:#f3f6fa;--nav:#122237;--blue:#1a5cab;--green:#1d6b3a}
*{box-sizing:border-box}body{margin:0;background:var(--canvas);color:var(--ink);font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:var(--blue);text-underline-offset:3px}header{background:var(--nav);color:#fff;padding:28px 32px}header h1{margin:0 0 4px;font-size:26px}
header p{margin:0;color:#c9d6e6}header a{color:#9cc7ff}main{max-width:1240px;margin:0 auto;padding:24px 32px 48px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin:0 0 28px}
.card{background:var(--paper);border:1px solid var(--line);border-left:6px solid var(--c);border-radius:10px;padding:16px 18px}
.card h2{margin:0;font-size:18px}.card .ref{color:var(--muted);font-size:12px;word-break:break-all}.card .state{color:var(--c);font-weight:700;margin:6px 0}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}.chip{border-radius:999px;padding:1px 9px;font-size:12px;font-weight:600;color:#fff;background:var(--c)}
.chip.zero{background:#e7edf4;color:var(--muted)}section{background:var(--paper);border:1px solid var(--line);border-radius:10px;padding:18px 20px;margin:0 0 20px}
section h2{margin:0 0 8px;font-size:20px}.controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:0 0 20px}
.controls label{display:flex;gap:5px;align-items:center;background:var(--paper);border:1px solid var(--line);border-radius:8px;padding:5px 10px}
.controls input[type=search]{border:1px solid var(--line);border-radius:8px;padding:6px 10px;min-width:260px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--muted);font-weight:600;position:sticky;top:0;background:var(--paper)}td.sev{font-weight:700;color:var(--c);white-space:nowrap}
td code{font-size:12px;word-break:break-all}.muted{color:var(--muted)}.fix{color:var(--green);font-weight:600}details summary{cursor:pointer;color:var(--muted)}
ul.files{columns:2;margin:6px 0 0;padding-left:20px}footer{color:var(--muted);font-size:13px}"""

SCRIPT = """const q=document.getElementById('q'),fix=document.getElementById('fixable');
const boxes=[...document.querySelectorAll('input[data-level]')];
function apply(){const on=new Set(boxes.filter(b=>b.checked).map(b=>b.dataset.level)),t=q.value.toLowerCase();
for(const r of document.querySelectorAll('tr[data-sev]')){const show=on.has(r.dataset.sev)&&(!fix.checked||r.dataset.fix==='1')&&(!t||r.textContent.toLowerCase().includes(t));r.hidden=!show}
for(const s of document.querySelectorAll('section[data-image]')){const n=s.querySelectorAll('tr[data-sev]:not([hidden])').length;s.querySelector('.shown').textContent=n}}
[q,fix,...boxes].forEach(e=>e.addEventListener('input',apply));apply();"""


def esc(value):
    return html.escape(str(value), quote=True)


def worst(counts):
    for level in LEVELS[:4]:
        if counts[level]:
            return level
    return None


def group(matches):
    rows = {}
    for match in matches:
        vuln, art = match["vulnerability"], match["artifact"]
        key = (vuln["id"], art["name"], art["version"], art["type"])
        row = rows.setdefault(key, {
            "id": vuln["id"], "severity": vuln["severity"] if vuln["severity"] in LEVELS else "Unknown",
            "package": art["name"], "version": art["version"], "type": art["type"],
            "fix": ", ".join(vuln["fix"]["versions"]) if vuln["fix"]["state"] == "fixed" else "",
            "url": vuln.get("dataSource") or "", "risk": vuln.get("risk") or 0,
            "epss": max((e["epss"] for e in vuln.get("epss") or []), default=None),
            "aliases": sorted({r["id"] for r in match.get("relatedVulnerabilities", []) if r["id"] != vuln["id"]}),
            "paths": set(),
        })
        row["paths"].update(loc["path"] for loc in art.get("locations", []))
    return sorted(rows.values(), key=lambda r: (LEVELS.index(r["severity"]), -r["risk"], r["id"], r["package"]))


def table(rows):
    if not rows:
        return '<p class="fix">No matches.</p>'
    out = ['<table><thead><tr><th>Severity</th><th>Vulnerability</th><th>Package</th><th>Installed</th><th>Fixed in</th><th>EPSS</th><th>Found in</th></tr></thead><tbody>']
    for r in rows:
        vid = f'<a href="{esc(r["url"])}">{esc(r["id"])}</a>' if r["url"].startswith("https://") else esc(r["id"])
        if r["aliases"]:
            vid += f'<br><span class="muted">{esc(", ".join(r["aliases"]))}</span>'
        paths = sorted(r["paths"])
        found = f"<code>{esc(paths[0])}</code>" if len(paths) == 1 else (
            f'<details><summary>{len(paths)} files</summary>' + "<br>".join(f"<code>{esc(p)}</code>" for p in paths) + "</details>")
        epss = f'{r["epss"] * 100:.1f}%' if r["epss"] is not None else '<span class="muted">-</span>'
        fix = f'<span class="fix">{esc(r["fix"])}</span>' if r["fix"] else '<span class="muted">none</span>'
        out.append(f'<tr data-sev="{r["severity"]}" data-fix="{int(bool(r["fix"]))}" style="--c:{COLORS[r["severity"]]}">'
                   f'<td class="sev">{r["severity"]}</td><td>{vid}</td><td><code>{esc(r["package"])}</code><br><span class="muted">{esc(r["type"])}</span></td>'
                   f'<td><code>{esc(r["version"])}</code></td><td>{fix}</td><td>{epss}</td><td>{found}</td></tr>')
    out.append("</tbody></table>")
    return "".join(out)


def build(scans, grype, output, extras, commit, run_url):
    summary = json.loads((scans / "scan-summary.json").read_text(encoding="utf-8"))
    output.mkdir(parents=True, exist_ok=True)
    (output / "sbom").mkdir(exist_ok=True)
    (output / "vulnerabilities").mkdir(exist_ok=True)
    grype_version = db_built = "unknown"
    images = []
    for result in summary["results"]:
        cid = result["component"]
        report = json.loads((grype / f"{cid}.grype.json").read_text(encoding="utf-8"))
        grype_version = report["descriptor"]["version"]
        db_built = report["descriptor"].get("db", {}).get("status", {}).get("built", db_built)
        rows = group(report["matches"])
        shutil.copy(scans / result["file"], output / "sbom" / result["file"])
        shutil.copy(grype / f"{cid}.grype.json", output / "vulnerabilities" / f"{cid}.grype.json")
        images.append((result, rows, collections.Counter(r["severity"] for r in rows), len(report["matches"])))
    files = []
    for path in extras:
        if path.is_file():
            shutil.copy(path, output / "sbom" / path.name)
            files.append(f"sbom/{path.name}")
    files += [f"sbom/{r['file']}" for r, *_ in images] + [f"vulnerabilities/{r['component']}.grype.json" for r, *_ in images]

    cards, sections = [], []
    for result, rows, counts, raw in images:
        cid, level = result["component"], worst(counts)
        color = COLORS[level] if level else "var(--green)"
        state = f"{counts[level]} {level.lower()}" if level else "No critical, high, medium or low"
        fixable = sum(bool(r["fix"]) for r in rows)
        chips = "".join(f'<span class="chip{"" if counts[l] else " zero"}" style="--c:{COLORS[l]}">{l} {counts[l]}</span>' for l in LEVELS)
        cards.append(f'<div class="card" style="--c:{color}"><h2><a href="#{esc(cid)}">{esc(cid)}</a></h2>'
                     f'<div class="ref">{esc(result["reference"])}</div><div class="state">{esc(state)}</div>'
                     f'<div class="muted">{len(rows)} findings ({raw} matches across files), {fixable} with a fix &middot; {result["packages"]} packages</div><div class="chips">{chips}</div></div>')
        sections.append(f'<section id="{esc(cid)}" data-image="{esc(cid)}"><h2>{esc(cid)}</h2>'
                        f'<p class="muted"><code>{esc(result["scanReference"])}</code><br>{esc(result["platform"])}, scanned {esc(result["finished"])}. '
                        f'Showing <span class="shown">{len(rows)}</span> of {len(rows)}. '
                        f'<a href="sbom/{esc(result["file"])}">CycloneDX SBOM</a> &middot; <a href="vulnerabilities/{esc(cid)}.grype.json">Grype JSON</a></p>'
                        f"{table(rows)}</section>")

    generated = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    source = f'commit <code>{esc(commit[:12])}</code>' if commit else "local build"
    if run_url:
        source += f' &middot; <a href="{esc(run_url)}">workflow run</a>'
    boxes = "".join(f'<label><input type="checkbox" data-level="{l}" checked> {l}</label>' for l in LEVELS)
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ironlog image vulnerabilities</title><style>{CSS}</style></head><body>
<header><h1>Ironlog image SBOM and vulnerabilities</h1><p>Generated {esc(generated)} &middot; {source} &middot; {esc(summary["generator"])} &middot; Grype {esc(grype_version)}, database built {esc(db_built)}</p></header>
<main><div class="cards">{"".join(cards)}</div>
<div class="controls">{boxes}<label><input type="checkbox" id="fixable"> Fix available only</label><input type="search" id="q" placeholder="Filter by ID, package or path"></div>
{"".join(sections)}
<section><h2>Downloads</h2><ul class="files">{"".join(f'<li><a href="{esc(f)}">{esc(f)}</a></li>' for f in files)}</ul></section>
<footer><p>Findings are grouped per image by vulnerability and package version; "Found in" lists each binary or package database that contains it.
Matches are automated and untriaged. Image SBOMs describe current registry artifacts behind the repository's image tags, not a built or deployed appliance.</p></footer>
</main><script>{SCRIPT}</script></body></html>
"""
    (output / "index.html").write_text(page, encoding="utf-8")
    total = collections.Counter()
    for _, _, counts, _ in images:
        total.update(counts)
    print(f"Wrote {output / 'index.html'}: {len(images)} images, " + ", ".join(f"{l} {total[l]}" for l in LEVELS))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scans", type=Path, required=True, help="directory with scan-summary.json and image SBOMs")
    parser.add_argument("--grype", type=Path, required=True, help="directory with <id>.grype.json reports")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extra", type=Path, action="append", default=[], help="additional SBOM file to publish")
    args = parser.parse_args()
    server, repo, run = (os.environ.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    run_url = f"{server}/{repo}/actions/runs/{run}" if server and repo and run else ""
    build(args.scans, args.grype, args.output, args.extra, os.environ.get("GITHUB_SHA", ""), run_url)
