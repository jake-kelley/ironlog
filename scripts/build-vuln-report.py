#!/usr/bin/env python3
"""Build a self-contained HTML page of the BOM, image SBOMs and Grype findings.

Reads the declared inventory (--inventory), scan-summary.json and <id>.cdx.json
from --scans, and <id>.grype.json from --grype. Writes index.html plus
downloadable copies of the SBOMs and reports to --output. No network requests;
no external scripts, fonts or styles.
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
CATEGORY_ORDER = ["runtime", "optional-demo", "shipping-platform", "development-platform", "base-os-requirement",
                  "host-package", "conditional-host-tool", "build-tool", "development-tool"]
ECOSYSTEMS = {"golang": "Go module", "deb": "Debian package", "apk": "Alpine package", "npm": "npm", "rpm": "RPM",
              "pypi": "Python", "cargo": "Rust crate", "maven": "Java", "github": "GitHub Action"}

# Severity colors were checked with the dataviz palette validator as an adjacent
# set for each surface (lightness, chroma, CVD and normal-vision separation).
# Medium is under 3:1 on the light surface, so every mark carries a text label.
CSS = """
:root{color-scheme:light;--plane:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink-2:#52514e;--muted:#898781;
--line:#e1e0d9;--ring:rgba(11,11,11,.10);--link:#1c5cab;--hero-a:#10233d;--hero-b:#1d4f8f;
--critical:#8e2a8c;--high:#e34948;--medium:#eda100;--low:#2a78d6;--negligible:#898781;--unknown:#c3c2b7;
--good:#0ca30c;--good-ink:#006300;--warn:#fab219;--tint:#f0efec}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--plane:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;--ink-2:#c3c2b7;
--line:#2c2c2a;--ring:rgba(255,255,255,.10);--link:#86b6ef;--hero-a:#0b1626;--hero-b:#163a69;
--critical:#a845a6;--high:#d03b3b;--medium:#c98500;--low:#3987e5;--negligible:#898781;--unknown:#5e5d59;
--good-ink:#0ca30c;--tint:#262624}}
*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:64px}
body{margin:0;background:var(--plane);color:var(--ink);font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif}
a{color:var(--link);text-underline-offset:3px}code{font:12px/1.4 ui-monospace,SFMono-Regular,Consolas,monospace;word-break:break-all}
header{background:linear-gradient(120deg,var(--hero-a),var(--hero-b));color:#fff;padding:34px 0 30px}
header h1{margin:0 0 6px;font-size:28px;letter-spacing:-.01em}header p{margin:0;color:#cde2fb;font-size:14px}header a{color:#fff}
.wrap{max-width:1280px;margin:0 auto;padding:0 32px}
nav{position:sticky;top:0;z-index:5;background:color-mix(in srgb,var(--surface) 92%,transparent);backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}
nav .wrap{display:flex;gap:4px;overflow-x:auto}nav a{color:var(--ink-2);text-decoration:none;padding:13px 14px;font-weight:600;font-size:14px;border-bottom:2px solid transparent;white-space:nowrap}
nav a:hover{color:var(--ink);border-bottom-color:var(--line)}
main{padding:28px 0 56px}h2{font-size:22px;margin:40px 0 4px;letter-spacing:-.01em}h2+p.lead{margin:0 0 16px;color:var(--ink-2)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px}
.tile{background:var(--surface);border:1px solid var(--ring);border-radius:14px;padding:16px 18px}
.tile .k{color:var(--ink-2);font-size:13px;font-weight:600}.tile .v{font-size:34px;font-weight:700;line-height:1.15;margin-top:4px}
.tile .s{color:var(--muted);font-size:13px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:16px;margin-top:16px}
.card{background:var(--surface);border:1px solid var(--ring);border-radius:14px;padding:18px 20px;box-shadow:0 1px 2px var(--ring)}
.card h3{margin:0;font-size:18px;display:flex;align-items:center;gap:10px;justify-content:space-between}
.card .ref{color:var(--muted);font-size:12px;margin:2px 0 12px}.meta{display:flex;flex-wrap:wrap;gap:6px 18px;color:var(--ink-2);font-size:13px;margin-top:12px}
.meta b{color:var(--ink)}
.bar{display:flex;gap:2px;height:14px;margin:6px 0 10px}.bar span{display:block;height:100%;min-width:4px}
.bar span:first-child{border-radius:4px 0 0 4px}.bar span:last-child{border-radius:0 4px 4px 0}.bar span:only-child{border-radius:4px}
.bar.empty{background:var(--tint);border-radius:4px}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:13px;color:var(--ink-2)}.legend b{color:var(--ink);font-variant-numeric:tabular-nums}
.dot{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.pill{display:inline-flex;align-items:center;gap:6px;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;background:var(--tint);color:var(--ink);white-space:nowrap}
.pill.good{background:color-mix(in srgb,var(--good) 16%,transparent);color:var(--good-ink)}
.pill.warn{background:color-mix(in srgb,var(--warn) 26%,transparent)}
.panel{background:var(--surface);border:1px solid var(--ring);border-radius:14px;padding:6px 18px 16px;margin-top:16px}
.panel h3{font-size:16px;margin:12px 0 6px}.panel ul{margin:0;padding-left:20px;color:var(--ink-2)}
.controls{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:6px 0 14px}
.controls label{display:inline-flex;gap:6px;align-items:center;background:var(--surface);border:1px solid var(--ring);border-radius:999px;padding:4px 12px;font-size:13px;cursor:pointer}
input[type=search]{background:var(--surface);color:var(--ink);border:1px solid var(--ring);border-radius:999px;padding:7px 14px;min-width:280px;font:inherit;font-size:14px}
.tablewrap{background:var(--surface);border:1px solid var(--ring);border-radius:14px;overflow:auto;max-height:640px}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top}
th{position:sticky;top:0;background:var(--surface);color:var(--ink-2);font-weight:600;z-index:1;box-shadow:0 1px 0 var(--line)}
tbody tr:hover{background:var(--tint)}td.num{text-align:right;font-variant-numeric:tabular-nums}.sub{color:var(--muted);font-size:12px}
details.img{margin-top:12px}details.img>summary{cursor:pointer;list-style:none;background:var(--surface);border:1px solid var(--ring);border-radius:14px;padding:12px 18px;display:flex;gap:14px;align-items:center;flex-wrap:wrap}
details.img>summary::before{content:"\\25B8";color:var(--muted)}details.img[open]>summary::before{content:"\\25BE"}
details.img[open]>summary{border-radius:14px 14px 0 0;border-bottom:none}details.img[open] .tablewrap{border-radius:0 0 14px 14px}
details.img>summary h3{margin:0;font-size:16px}details.files summary{cursor:pointer;color:var(--ink-2)}
.fix{color:var(--good-ink);font-weight:600}ul.dl{columns:3;margin:8px 0 0;padding-left:20px}
footer{color:var(--muted);font-size:13px;margin-top:40px}
#tip{position:fixed;pointer-events:none;z-index:20;background:var(--ink);color:var(--surface);font-size:12px;padding:6px 9px;border-radius:6px;display:none;white-space:nowrap}
"""

SCRIPT = """
const tip=document.getElementById('tip');
document.addEventListener('mousemove',e=>{const t=e.target.closest('[data-tip]');if(!t){tip.style.display='none';return}
tip.textContent=t.dataset.tip;tip.style.display='block';tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY+14)+'px'});
function bind(scope){const root=document.getElementById(scope),q=root.querySelector('input[type=search]'),fix=root.querySelector('input[data-fix]');
const boxes=[...root.querySelectorAll('input[data-level]')];
function apply(){const on=new Set(boxes.map(b=>b.checked?b.dataset.level:null)),t=q.value.toLowerCase();
for(const r of root.querySelectorAll('tbody tr')){let show=!t||r.textContent.toLowerCase().includes(t);
if(boxes.length)show=show&&on.has(r.dataset.sev);if(fix&&fix.checked)show=show&&r.dataset.fix==='1';r.hidden=!show}
for(const c of root.querySelectorAll('[data-count]')){c.textContent=c.closest('details,section').querySelectorAll('tbody tr:not([hidden])').length}
if(t)for(const d of root.querySelectorAll('details.img'))if(d.querySelector('tbody tr:not([hidden])'))d.open=true}
[q,fix,...boxes].filter(Boolean).forEach(e=>e.addEventListener('input',apply));apply()}
['bom','packages','vulnerabilities'].forEach(bind);
"""


def esc(value):
    return html.escape(str(value), quote=True)


def num(value):
    return f"{value:,}"


def level_of(severity):
    return severity if severity in LEVELS else "Unknown"


def sev_label(level):
    return f'<span class="dot" style="background:var(--{level.lower()})"></span>{level}'


def bar(counts):
    total = sum(counts[level] for level in LEVELS)
    if not total:
        return '<div class="bar empty" data-tip="No findings"></div>'
    parts = "".join(f'<span style="flex:{counts[l]};background:var(--{l.lower()})" data-tip="{l}: {counts[l]} of {total}"></span>'
                    for l in LEVELS if counts[l])
    return f'<div class="bar" role="img" aria-label="{esc(", ".join(f"{l} {counts[l]}" for l in LEVELS if counts[l]))}">{parts}</div>'


def legend(counts):
    return '<div class="legend">' + "".join(f'<span>{sev_label(l)} <b>{counts[l]}</b></span>' for l in LEVELS if counts[l]) + "</div>"


def status_pill(counts):
    for level in LEVELS[:4]:
        if counts[level]:
            return f'<span class="pill">{sev_label(level)}: {counts[level]}</span>'
    return '<span class="pill good">&#10003; No critical, high, medium or low</span>'


def pkg_key(name, version, purl):
    eco = purl.split(":", 1)[-1].split("/", 1)[0] if purl.startswith("pkg:") else ""
    return (eco, name, version)


def group_vulns(matches):
    rows = {}
    for match in matches:
        vuln, art = match["vulnerability"], match["artifact"]
        key = (vuln["id"], art["name"], art["version"], art["type"])
        row = rows.setdefault(key, {
            "id": vuln["id"], "severity": level_of(vuln["severity"]), "package": art["name"], "version": art["version"],
            "type": art["type"], "fix": ", ".join(vuln["fix"]["versions"]) if vuln["fix"]["state"] == "fixed" else "",
            "url": vuln.get("dataSource") or "", "risk": vuln.get("risk") or 0,
            "epss": max((e["epss"] for e in vuln.get("epss") or []), default=None),
            "aliases": sorted({r["id"] for r in match.get("relatedVulnerabilities", []) if r["id"] != vuln["id"]}),
            "pkg": pkg_key(art["name"], art["version"], art.get("purl") or ""), "paths": set(),
        })
        row["paths"].update(loc["path"] for loc in art.get("locations", []))
    return sorted(rows.values(), key=lambda r: (LEVELS.index(r["severity"]), -r["risk"], r["id"], r["package"]))


def group_packages(cdx):
    packages, os_name = {}, ""
    for comp in cdx.get("components", []):
        if comp["type"] == "operating-system":
            os_name = f'{comp.get("name", "")} {comp.get("version", "")}'.strip()
            continue
        if comp["type"] == "file":
            continue
        purl = comp.get("purl") or ""
        key = pkg_key(comp["name"], comp.get("version", ""), purl)
        row = packages.setdefault(key, {"name": comp["name"], "version": comp.get("version", ""), "eco": key[0],
                                        "licenses": set(), "count": 0})
        row["count"] += 1
        for lic in comp.get("licenses", []):
            value = lic.get("expression") or lic.get("license", {}).get("id") or lic.get("license", {}).get("name")
            if value:
                row["licenses"].add(value)
    return packages, os_name


def found_in(paths):
    paths = sorted(paths)
    if len(paths) == 1:
        return f"<code>{esc(paths[0])}</code>"
    return (f'<details class="files"><summary>{len(paths)} files</summary>'
            + "<br>".join(f"<code>{esc(p)}</code>" for p in paths) + "</details>")


def vuln_table(rows):
    if not rows:
        return '<p class="fix" style="padding:12px 18px;margin:0">No matches.</p>'
    out = ['<table><thead><tr><th>Severity</th><th>Vulnerability</th><th>Package</th><th>Installed</th><th>Fixed in</th>'
           '<th class="num">EPSS</th><th>Found in</th></tr></thead><tbody>']
    for r in rows:
        vid = f'<a href="{esc(r["url"])}">{esc(r["id"])}</a>' if r["url"].startswith("https://") else esc(r["id"])
        if r["aliases"]:
            vid += f'<div class="sub">{esc(", ".join(r["aliases"]))}</div>'
        epss = f'{r["epss"] * 100:.1f}%' if r["epss"] is not None else '<span class="sub">-</span>'
        fix = f'<span class="fix">{esc(r["fix"])}</span>' if r["fix"] else '<span class="sub">none</span>'
        out.append(f'<tr data-sev="{r["severity"]}" data-fix="{int(bool(r["fix"]))}"><td>{sev_label(r["severity"])}</td>'
                   f'<td>{vid}</td><td><code>{esc(r["package"])}</code><div class="sub">{esc(r["type"])}</div></td>'
                   f'<td><code>{esc(r["version"])}</code></td><td>{fix}</td><td class="num">{epss}</td><td>{found_in(r["paths"])}</td></tr>')
    return "".join(out) + "</tbody></table>"


def package_table(packages, vulns):
    by_pkg = collections.defaultdict(list)
    for v in vulns:
        by_pkg[v["pkg"]].append(v["severity"])
    out = ['<table><thead><tr><th>Package</th><th>Version</th><th>Type</th><th>License</th><th class="num">Copies</th>'
           '<th>Vulnerabilities</th></tr></thead><tbody>']
    for key, p in sorted(packages.items(), key=lambda kv: (kv[1]["eco"], kv[1]["name"].lower(), kv[1]["version"])):
        sevs = by_pkg.get(key, [])
        if sevs:
            worst = min(sevs, key=LEVELS.index)
            vcell = f'{sev_label(worst)} <span class="sub">{len(sevs)} total</span>'
        else:
            vcell = '<span class="sub">none matched</span>'
        lic = esc(", ".join(sorted(p["licenses"]))) or '<span class="sub">not recorded</span>'
        out.append(f'<tr><td><code>{esc(p["name"])}</code></td><td><code>{esc(p["version"])}</code></td>'
                   f'<td>{esc(ECOSYSTEMS.get(p["eco"], p["eco"] or "other"))}</td><td>{lic}</td><td class="num">{p["count"]}</td><td>{vcell}</td></tr>')
    return "".join(out) + "</tbody></table>"


def bom_table(components):
    order = {c: i for i, c in enumerate(CATEGORY_ORDER)}
    out = ['<table><thead><tr><th>Component</th><th>Category</th><th>Version</th><th>License</th><th>Supplier</th>'
           '<th>FOCI review</th></tr></thead><tbody>']
    for c in sorted(components, key=lambda c: (order.get(c["category"], 99), c["name"].lower())):
        foci = c["foci_status"]
        pill = ('<span class="pill">Unreviewed</span>' if foci == "UNREVIEWED"
                else f'<span class="pill warn">&#9888; {esc(foci.replace("_", " ").capitalize())}</span>')
        image = f'<div class="sub"><code>{esc(c["image"])}</code></div>' if c.get("image") else ""
        version = esc(c["version"]) if c["version"] else '<span class="sub">unpinned</span>'
        lic = esc(c["license_expression"]) if c["license_expression"] else '<span class="sub">not recorded</span>'
        out.append(f'<tr><td><b>{esc(c["name"])}</b>{image}</td><td>{esc(c["category"].replace("-", " "))}</td><td><code>{version}</code></td>'
                   f'<td>{lic}</td><td>{esc(c["supplier"])}</td><td>{pill}</td></tr>')
    return "".join(out) + "</tbody></table>"


def search(placeholder):
    return f'<input type="search" placeholder="{esc(placeholder)}" aria-label="{esc(placeholder)}">'


def build(inventory_path, scans, grype, output, extras, commit, run_url):
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    summary = json.loads((scans / "scan-summary.json").read_text(encoding="utf-8"))
    for sub in ("sbom", "vulnerabilities"):
        (output / sub).mkdir(parents=True, exist_ok=True)
    grype_version = db_built = "unknown"
    images = []
    for result in summary["results"]:
        cid = result["component"]
        report = json.loads((grype / f"{cid}.grype.json").read_text(encoding="utf-8"))
        grype_version = report["descriptor"]["version"]
        db_built = report["descriptor"].get("db", {}).get("status", {}).get("built", db_built)
        packages, os_name = group_packages(json.loads((scans / result["file"]).read_text(encoding="utf-8")))
        vulns = group_vulns(report["matches"])
        shutil.copy(scans / result["file"], output / "sbom" / result["file"])
        shutil.copy(grype / f"{cid}.grype.json", output / "vulnerabilities" / f"{cid}.grype.json")
        images.append({"r": result, "packages": packages, "os": os_name, "vulns": vulns, "raw": len(report["matches"]),
                       "counts": collections.Counter(v["severity"] for v in vulns)})
    shutil.copy(inventory_path, output / "sbom" / inventory_path.name)
    files = [f"sbom/{inventory_path.name}"]
    for path in extras:
        if path.is_file():
            shutil.copy(path, output / "sbom" / path.name)
            files.append(f"sbom/{path.name}")
    files += [f"sbom/{i['r']['file']}" for i in images] + [f"vulnerabilities/{i['r']['component']}.grype.json" for i in images]

    total = collections.Counter()
    for i in images:
        total.update(i["counts"])
    components = inventory["components"]
    n_vulns = sum(total.values())
    occurrences = sum(i["r"]["packages"] for i in images)
    unique_pkgs = sum(len(i["packages"]) for i in images)
    fixable = sum(bool(v["fix"]) for i in images for v in i["vulns"])
    foci_flags = sum(c["foci_status"] != "UNREVIEWED" for c in components)
    tiles = [
        ("Declared components", num(len(components)), f'{sum(c["category"] == "runtime" for c in components)} runtime, {len(images)} images scanned'),
        ("Image packages", num(unique_pkgs), f"{num(occurrences)} copies across images"),
        ("Vulnerabilities", num(n_vulns), f"{num(sum(i['raw'] for i in images))} matches across files"),
        ("Critical + high", num(total["Critical"] + total["High"]), f'{total["Critical"]} critical, {total["High"]} high'),
        ("Fix available", num(fixable), f"of {num(n_vulns)} vulnerabilities"),
    ]
    tile_html = "".join(f'<div class="tile"><div class="k">{k}</div><div class="v">{v}</div><div class="s">{s}</div></div>' for k, v, s in tiles)

    cards = []
    for i in images:
        r = i["r"]
        cards.append(f'<div class="card"><h3><a href="#pkg-{esc(r["component"])}">{esc(r["component"])}</a>{status_pill(i["counts"])}</h3>'
                     f'<div class="ref">{esc(r["reference"])}</div>{bar(i["counts"])}{legend(i["counts"])}'
                     f'<div class="meta"><span><b>{num(len(i["packages"]))}</b> packages</span><span><b>{len(i["vulns"])}</b> vulnerabilities</span>'
                     f'<span><b>{sum(bool(v["fix"]) for v in i["vulns"])}</b> fixable</span><span>{esc(i["os"] or "OS unknown")}</span>'
                     f'<span>{esc(r["platform"])}</span></div></div>')

    gaps = "".join(f"<li>{esc(g)}</li>" for g in inventory.get("known_gaps", []))
    excluded = "".join(f"<li>{esc(e)}</li>" for e in inventory.get("excluded", []))
    posture = (f'<div class="panel"><h3>Assessment</h3><div class="meta" style="margin-top:0">'
               f'<span>Assessed <b>{esc(inventory.get("assessment_date", ""))}</b></span>'
               f'<span>FOSS <span class="pill">{esc(inventory.get("foss_status", "").replace("_", " ").lower())}</span></span>'
               f'<span>FOCI <span class="pill warn">&#9888; {esc(inventory.get("foci_status", "").replace("_", " ").lower())}</span></span>'
               f'<span><b>{foci_flags}</b> components flagged for FOCI review</span></div>'
               f'<h3>Known gaps</h3><ul>{gaps}</ul><h3>Excluded</h3><ul>{excluded}</ul></div>')

    pkg_sections = []
    for i in images:
        r = i["r"]
        pkg_sections.append(f'<details class="img" id="pkg-{esc(r["component"])}"><summary><h3>{esc(r["component"])}</h3>'
                            f'<span class="sub"><code>{esc(r["scanReference"])}</code></span>'
                            f'<span class="pill"><span data-count>{len(i["packages"])}</span>&nbsp;shown</span></summary>'
                            f'<div class="tablewrap">{package_table(i["packages"], i["vulns"])}</div></details>')
    vuln_sections = []
    for i in images:
        r = i["r"]
        vuln_sections.append(f'<details class="img" id="vuln-{esc(r["component"])}"{" open" if i["counts"]["Critical"] + i["counts"]["High"] else ""}>'
                             f'<summary><h3>{esc(r["component"])}</h3>{status_pill(i["counts"])}'
                             f'<span class="pill"><span data-count>{len(i["vulns"])}</span>&nbsp;shown</span>'
                             f'<span class="sub">{esc(r["platform"])}, scanned {esc(r["finished"])}</span></summary>'
                             f'<div class="tablewrap">{vuln_table(i["vulns"])}</div></details>')

    generated = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    source = f'commit <code style="color:#fff">{esc(commit[:12])}</code>' if commit else "local build"
    if run_url:
        source += f' &middot; <a href="{esc(run_url)}">workflow run</a>'
    boxes = "".join(f'<label><input type="checkbox" data-level="{l}" checked>{sev_label(l)}</label>' for l in LEVELS)
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ironlog BOM, SBOM and vulnerabilities</title><style>{CSS}</style></head><body>
<header><div class="wrap"><h1>Ironlog BOM, SBOM and vulnerabilities</h1>
<p>Generated {esc(generated)} &middot; {source} &middot; {esc(summary["generator"])} &middot; Grype {esc(grype_version)}, database built {esc(db_built)}</p></div></header>
<nav><div class="wrap"><a href="#overview">Overview</a><a href="#bom">BOM</a><a href="#packages">Image packages</a><a href="#vulnerabilities">Vulnerabilities</a><a href="#downloads">Downloads</a></div></nav>
<main class="wrap">
<section id="overview"><div class="tiles">{tile_html}</div><div class="cards">{"".join(cards)}</div>{posture}</section>
<section id="bom"><h2>Bill of materials</h2><p class="lead">Declared constituent software from <code>sbom/ironlog.inventory.json</code>. Versions and licenses are declared, not measured on an appliance.</p>
<div class="controls">{search("Filter components, suppliers or licenses")}<span class="pill"><span data-count>{len(components)}</span>&nbsp;shown</span></div>
<div class="tablewrap">{bom_table(components)}</div></section>
<section id="packages"><h2>Image packages (SBOM)</h2><p class="lead">Packages Syft found in each runtime image. Copies counts the same package version found in more than one binary or database.</p>
<div class="controls">{search("Filter packages, versions or licenses")}</div>{"".join(pkg_sections)}</section>
<section id="vulnerabilities"><h2>Vulnerabilities</h2><p class="lead">Grype matches grouped by vulnerability and package version. Automated and untriaged.</p>
<div class="controls">{boxes}<label><input type="checkbox" data-fix>Fix available only</label>{search("Filter by ID, package or path")}</div>
{"".join(vuln_sections)}</section>
<section id="downloads"><h2>Downloads</h2><ul class="dl">{"".join(f'<li><a href="{esc(f)}">{esc(f)}</a></li>' for f in files)}</ul></section>
<footer>Image SBOMs describe current registry artifacts behind the repository's image tags, identified by manifest digest; not a built or deployed appliance.
This page is generated by <code>scripts/build-vuln-report.py</code>.</footer>
</main><div id="tip" role="tooltip"></div><script>{SCRIPT}</script></body></html>
"""
    (output / "index.html").write_text(page, encoding="utf-8")
    print(f"Wrote {output / 'index.html'}: {len(components)} declared components, {len(images)} images, "
          f"{unique_pkgs} packages, " + ", ".join(f"{l} {total[l]}" for l in LEVELS))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True, help="declared inventory JSON")
    parser.add_argument("--scans", type=Path, required=True, help="directory with scan-summary.json and image SBOMs")
    parser.add_argument("--grype", type=Path, required=True, help="directory with <id>.grype.json reports")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extra", type=Path, action="append", default=[], help="additional SBOM file to publish")
    args = parser.parse_args()
    server, repo, run = (os.environ.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    run_url = f"{server}/{repo}/actions/runs/{run}" if server and repo and run else ""
    build(args.inventory, args.scans, args.grype, args.output, args.extra, os.environ.get("GITHUB_SHA", ""), run_url)
