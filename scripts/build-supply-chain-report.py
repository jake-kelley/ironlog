#!/usr/bin/env python3
"""Build offline HTML report from existing BOM/review/SBOM evidence.

Requires markdown-it-py for rendering repository Markdown. Does not fetch
sources, execute containers, or change assessment findings.
"""
import base64
import html
import json
import os
from pathlib import Path
import re

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/reports/ironlog-supply-chain-report.html"
inventory = json.loads((ROOT / "sbom/ironlog.inventory.json").read_text())
scans = json.loads((ROOT / "sbom/registry-snapshot/scan-summary.json").read_text())


def link(path):
    return Path(os.path.relpath(ROOT / path, OUTPUT.parent)).as_posix()


def render_document(path, prefix):
    text = (ROOT / path).read_text(encoding="utf-8")
    text = re.sub(r"\A---\s*\n.*?\n---\s*\n", "", text, flags=re.S)
    text = re.sub(r"\A# [^\n]+\n", "", text)
    renderer = MarkdownIt("commonmark", {"html": False}).enable("table")
    tokens = renderer.parse(text)
    for token in tokens:
        for child in token.children or []:
            if child.type != "link_open":
                continue
            href = child.attrGet("href") or ""
            if "://" not in href and not href.startswith("#"):
                target = ((ROOT / path).parent / href).resolve()
                child.attrSet("href", Path(os.path.relpath(target, OUTPUT.parent)).as_posix())
            elif href.startswith("https://"):
                child.attrSet("target", "_blank")
                child.attrSet("rel", "noopener noreferrer")
    rendered = renderer.renderer.render(tokens, renderer.options, {})
    rendered = re.sub(r"<h2>(.*?)</h2>", lambda m: '<h2 id="' + prefix + "-" + re.sub(r"[^a-z0-9]+", "-", re.sub("<[^>]+>", "", m[1]).lower()).strip("-") + '">' + m[1] + "</h2>", rendered)
    return re.sub(r"(<table>.*?</table>)", r'<div class="table-scroll">\1</div>', rendered, flags=re.S)


packages = []
scan_cards = []
for result in scans["results"]:
    name = result["component"]
    success = result["status"] == "success"
    count = result.get("packages", 0)
    label = f"{count:,} package records" if success else "Blocked · pull rate limit"
    scan_cards.append(f'<div class="scan-card"><strong>{html.escape(name.title())}</strong><span class="pill {"blue" if success else "amber"}">{label}</span><small>{html.escape(result.get("platform", "linux/arm64"))} · final filesystem</small></div>')
    if not success:
        continue
    data = json.loads((ROOT / "sbom/registry-snapshot" / result["file"]).read_text(encoding="utf-8"))
    for component in data.get("components", []):
        if component["type"] in ("file", "operating-system"):
            continue
        licenses = []
        for choice in component.get("licenses", []):
            license_data = choice.get("license", {})
            licenses.append(choice.get("expression") or license_data.get("id") or license_data.get("name") or "Unresolved")
        packages.append({"image": name, "name": component["name"], "version": component.get("version", "Unknown"), "license": "; ".join(licenses) or "Unresolved", "purl": component.get("purl", "")})

artifact_paths = [
    ("Component BOM · CSV", "sbom/ironlog-bom.csv"),
    ("Declared SBOM · CycloneDX 1.6", "sbom/ironlog.cdx.json"),
    ("Maintained source inventory · JSON", "sbom/ironlog.inventory.json"),
    ("Digest identity & scan evidence · JSON", "sbom/registry-snapshot/scan-summary.json"),
]
artifact_paths += [(r["component"].title() + " package SBOM · CycloneDX 1.6", "sbom/registry-snapshot/" + r["file"]) for r in scans["results"] if r["status"] == "success"]
downloads = "".join(f'<a class="download" href="{link(path)}" download><span>{html.escape(name)}</span><small>{(ROOT / path).stat().st_size / 1024:,.0f} KB ↗</small></a>' for name, path in artifact_paths)
architecture = ROOT / "docs/images/ironlog-architecture/ironlog-architecture.svg"
diagram = ''
if architecture.exists():
    encoded = base64.b64encode(architecture.read_bytes()).decode()
    diagram = f'<details class="architecture"><summary>View current architecture</summary><img alt="Ironlog architecture with sources, ingestion, data and application lanes" src="data:image/svg+xml;base64,{encoded}"></details>'

template = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light"><meta name="description" content="Ironlog owner-operated deployment: FOSS licensing, FOCI supplier review, bill of materials and SBOM evidence.">
<title>Ironlog | FOSS, FOCI & Supply-Chain Report</title>
<style>
:root{--ink:#18283d;--muted:#596a80;--line:#dce4ee;--paper:#fff;--canvas:#f3f6fa;--nav:#122237;--blue:#1a5cab;--amber:#845600;--red:#a52e35}*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:28px}body{margin:0;background:var(--canvas);color:var(--ink);font:15px/1.65 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif}a{color:var(--blue);text-underline-offset:3px}a:hover{color:#003469}button,input,select{font:inherit}button,.button{cursor:pointer;border:1px solid var(--line);border-radius:8px;background:#fff;color:var(--ink);padding:8px 13px;text-decoration:none}button:hover,.button:hover{background:#edf3fa}button:disabled{opacity:.45;cursor:default}:focus-visible{outline:3px solid #64aaff;outline-offset:3px}.skip{position:fixed;top:-100px;left:15px;z-index:10;background:white;padding:10px}.skip:focus{top:15px}
aside{position:fixed;width:236px;inset:0 auto 0 0;background:var(--nav);color:#e9f1fc;padding:32px 23px;display:flex;flex-direction:column}.brand{font-size:27px;font-weight:750;letter-spacing:-1px}.brand i{font-style:normal;color:#78b6fc}.nav-kicker{color:#b4c6db;font-size:11px;letter-spacing:1.6px;text-transform:uppercase;margin:3px 0 35px}nav a{display:block;color:#c2d1e3;text-decoration:none;font-size:14px;padding:10px 12px;border-radius:7px;margin:3px 0}nav a:hover{color:#fff;background:#213951}nav .n{display:inline-block;color:#829bb6;width:26px;font-size:11px}.aside-foot{margin-top:auto;padding-top:25px;border-top:1px solid #33465c;font-size:12px;color:#b0c2d7}.aside-foot strong{display:block;color:#e8f0f8;margin-top:7px}.offline-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#77cab1;margin-right:6px}main{margin-left:236px;max-width:1530px;padding:42px 48px 65px}.topline{display:flex;align-items:center;justify-content:space-between;gap:16px}.eyebrow{font-size:11px;text-transform:uppercase;letter-spacing:1.7px;color:#526d8a;font-weight:750}.report-meta{font-size:12px;color:var(--muted);margin-top:5px}h1{font-size:clamp(32px,3.3vw,48px);line-height:1.12;letter-spacing:-1.5px;margin:22px 0 14px}h1 span{font-weight:400;color:#536a84}.lead{max-width:800px;font-size:17px;color:var(--muted);margin-bottom:26px}.status-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px}.status{background:#fff;border:1px solid var(--line);border-top:4px solid var(--blue);padding:20px 21px;border-radius:12px}.status.red{border-top-color:#c54d56}.status.amber{border-top-color:#be8b25}.status .label{font-size:11px;letter-spacing:1.3px;text-transform:uppercase;font-weight:750;color:var(--muted)}.status strong{font-size:22px;display:block;line-height:1.25;margin:9px 0}.status p{font-size:13px;color:var(--muted);margin:0}.owner-note{display:flex;gap:13px;background:#eaf2fc;border:1px solid #cbdcf3;border-radius:10px;padding:17px 20px;margin:20px 0}.owner-note strong{display:block}.owner-note p{margin:3px 0 0;font-size:14px}.note-mark{font-size:22px;color:var(--blue)}
.section{background:var(--paper);border:1px solid var(--line);border-radius:14px;margin:27px 0;padding:30px 32px}.section-head{display:flex;align-items:baseline;gap:14px;margin-bottom:15px}.section-number{font-size:12px;color:var(--blue);font-weight:750;letter-spacing:1px}.section h2{font-size:23px;line-height:1.3;letter-spacing:-.5px;margin:31px 0 14px;scroll-margin-top:30px}.section-head h2{margin:0}.section h3{font-size:17px;margin:25px 0 10px}.section p{margin:12px 0}.section .intro{color:var(--muted);font-size:14px}.section li{margin:7px 0}.section ol,.section ul{padding-left:23px}code{font:12px/1.6 ui-monospace,SFMono-Regular,Consolas,monospace;background:#edf2f7;padding:2px 5px;border-radius:4px;overflow-wrap:anywhere}pre{background:#14263b;color:#dbeafa;border-radius:8px;padding:16px;overflow-x:auto;line-height:1.5}pre code{background:none;color:inherit;padding:0}blockquote{margin:20px 0;border-left:4px solid #6b96cb;background:#f1f6fc;padding:12px 20px;color:#2c4666}blockquote p{margin:7px 0}.table-scroll{overflow-x:auto;border:1px solid var(--line);border-radius:9px;margin:16px 0}table{border-collapse:collapse;width:100%;font-size:13px;line-height:1.55}th{background:#edf2f8;color:#354d68;font-size:11px;text-transform:uppercase;letter-spacing:.5px;text-align:left;padding:12px 13px}td{padding:13px;vertical-align:top;border-top:1px solid var(--line)}tbody tr:hover{background:#f7faff}table td:first-child{font-weight:600}td,th{overflow-wrap:anywhere}td p{margin:0}.pill{display:inline-block;border-radius:5px;font-size:11px;font-weight:650;padding:4px 8px;line-height:1.4}.pill.blue{background:#e8f1fd;color:#245d9d}.pill.amber{background:#fff0d0;color:#805500}.pill.red{background:#fbe8e9;color:#a52e35}.toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin:18px 0 9px}.toolbar input{min-width:200px;flex:1}.toolbar input,.toolbar select{border:1px solid #becddd;border-radius:8px;padding:10px 12px;background:#fff;color:var(--ink)}.count{font-size:12px;color:var(--muted);margin:8px 0}.inventory-table{min-width:740px}.inventory-table td:nth-child(1){width:18%}.inventory-table td:nth-child(2){width:13%}.inventory-table td:nth-child(3){width:15%}.inventory-table td:nth-child(4){width:20%}.inventory-table td:nth-child(5){width:34%}.package-table{min-width:650px}.package-table td:nth-child(2){max-width:330px;overflow-wrap:anywhere}.package-table td:nth-child(4){max-width:250px}.pager{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:12px}.pager-controls{display:flex;gap:8px}.scan-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:9px;margin:18px 0}.scan-card{display:flex;flex-direction:column;gap:9px;padding:15px;border:1px solid var(--line);border-radius:9px}.scan-card strong{font-size:14px}.scan-card small{font-size:11px;color:var(--muted)}.downloads{display:grid;grid-template-columns:1fr 1fr;gap:10px}.download{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:15px 17px;border:1px solid var(--line);border-radius:8px;text-decoration:none;font-size:13px;font-weight:600}.download:hover{background:#f1f6fc}.download small{white-space:nowrap;color:var(--muted);font-weight:400}.architecture{margin:20px 0}.architecture summary{cursor:pointer;font-size:13px;color:var(--blue);font-weight:650}.architecture img{width:100%;height:auto;margin-top:16px;border:1px solid var(--line);border-radius:9px}.method-note{background:#f6f8fb;padding:15px 17px;border-radius:8px;font-size:13px;color:var(--muted)}footer{color:var(--muted);font-size:12px;margin:30px 3px}.hidden{display:none!important}
@media(max-width:1100px){main{padding:30px 24px}.scan-grid{grid-template-columns:repeat(3,minmax(0,1fr))}.section{padding:25px 23px}.status{padding:16px}.status strong{font-size:19px}}
@media(max-width:760px){aside{position:static;width:auto;padding:16px 20px}.nav-kicker,.aside-foot{display:none}nav{display:flex;gap:4px;overflow-x:auto;margin-top:9px}nav a{white-space:nowrap;padding:7px 9px;font-size:12px}nav .n{display:none}main{margin:0;padding:25px 16px}.section{padding:22px 18px}.status-grid{grid-template-columns:1fr}.scan-grid{grid-template-columns:1fr 1fr}.downloads{grid-template-columns:1fr}.topline{align-items:flex-start}h1{font-size:34px}.toolbar input{width:100%;flex-basis:100%}.topline button{font-size:12px}.report-meta{max-width:230px}}
@media print{body{font-size:10pt;background:white;color:#111}aside,.toolbar,.pager,.topline button,.skip,.architecture{display:none!important}main{margin:0;max-width:none;padding:0}.section{border:0;border-top:1px solid #ccc;border-radius:0;padding:16px 0;margin:18px 0}.status-grid{grid-template-columns:repeat(3,1fr)}.status{break-inside:avoid}.status strong{font-size:15pt}.table-scroll{overflow:visible;border:0}table{font-size:8pt}th,td{padding:7px}thead{display:table-header-group}tr{break-inside:avoid}.scan-grid{grid-template-columns:repeat(3,1fr)}h2,h3{break-after:avoid}pre{white-space:pre-wrap}#package-explorer{display:none}.downloads{grid-template-columns:1fr 1fr}a{color:#1d4d85}.section-number{font-size:9pt}.method-note{background:#f1f1f1}*{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
</style></head><body>
<a class="skip" href="#main">Skip to report</a>
<aside><div class="brand">ironlog<i>.</i></div><div class="nav-kicker">Supply-chain evidence</div><nav aria-label="Report navigation">
<a href="#summary"><span class="n">01</span>Decision summary</a><a href="#review-licensing-findings"><span class="n">02</span>FOSS & licensing</a><a href="#review-foci-findings"><span class="n">03</span>FOCI review</a><a href="#inventory"><span class="n">04</span>Bill of materials</a><a href="#sbom"><span class="n">05</span>SBOM & packages</a><a href="#downloads"><span class="n">06</span>Evidence files</a><a href="#review-closure-requirements"><span class="n">07</span>Closure requirements</a>
</nav><div class="aside-foot"><span class="offline-dot"></span>Offline HTML report<strong>Assessment · 03 Nov 2026</strong>Owner-operated deployment<br>No SaaS offering</div></aside>
<main id="main"><header id="summary"><div class="topline"><div><div class="eyebrow">Supplier assurance / technical assessment</div><div class="report-meta">03 November 2026 · Repository baseline <code>a568b20</code></div></div><button id="print-report" type="button">Print / Save PDF</button></div>
<h1>Ironlog supply-chain report<br><span>FOSS, FOCI & software inventory</span></h1><p class="lead">An evidence-based view of what Ironlog includes, which licensing requirements it meets, and what remains necessary before supplier approval.</p>
<div class="status-grid"><div class="status"><div class="label">Runtime licensing</div><strong>OSI-approved primary licenses</strong><p>Apache-2.0, AGPL-3.0-only and MPL-2.0. HyperDX and MongoDB (SSPL) removed 2026-11-03. Artifact-level license coverage remains incomplete.</p></div><div class="status amber"><div class="label">FOCI assurance</div><strong>Not established</strong><p>Disclosed foreign investment requires ownership/control review. No supplier clearance asserted.</p></div><div class="status"><div class="label">SBOM coverage</div><strong>@@SCANNED_IMAGE_COUNT@@ of @@RUNTIME_IMAGE_COUNT@@ runtime images</strong><p>@@COMPONENT_COUNT@@ declared components; @@PACKAGE_COUNT@@ package records. Release coverage remains incomplete.</p></div></div>
<div class="owner-note"><div class="note-mark" aria-hidden="true">◈</div><div><strong>Deployment context matters: owner-operated, not SaaS.</strong><p>Ironlog is deployed and operated by the system owner. Grafana is the single UI; no SSPL software remains in the stack. Ownership/control review remains separate from licensing. Ironlog itself is excluded as a separate software product.</p></div></div>
<div class="method-note"><strong>Reading this report:</strong> FOSS concerns software licensing. FOCI concerns foreign interests and control over suppliers. An SBOM lists software evidence. These are separate questions; none certifies the others.</div>@@DIAGRAM@@</header>
<section class="section" id="review"><div class="section-head"><span class="section-number">01–03</span><h2>Assessment & supporting evidence</h2></div><div class="prose">@@REVIEW@@</div></section>
<section class="section" id="inventory"><div class="section-head"><span class="section-number">04</span><h2>Declared component inventory</h2></div><p class="intro">Search all @@COMPONENT_COUNT@@ declared materials. Host requirements, optional development tools and build-time dependencies are labeled separately. Unknown versions and licenses remain unresolved.</p>
<div class="toolbar"><input id="bom-search" type="search" aria-label="Search declared components" placeholder="Search components, licenses, suppliers…"><select id="bom-category" aria-label="Filter component category"><option value="">All categories</option></select><button id="bom-clear" type="button">Clear</button></div><p class="count" id="bom-count" role="status" aria-live="polite"></p><div class="table-scroll"><table class="inventory-table"><thead><tr><th scope="col">Component</th><th scope="col">Declared version</th><th scope="col">Category / license</th><th scope="col">Supplier / FOCI status</th><th scope="col">Evidence & limitations</th></tr></thead><tbody id="bom-body"></tbody></table></div>
<details><summary>Full BOM: infrastructure, host packages & scope</summary><div class="prose">@@BOM@@</div></details></section>
<section class="section" id="sbom"><div class="section-head"><span class="section-number">05</span><h2>SBOM coverage & package evidence</h2></div><p class="intro">Syft 1.56.0 · Linux/ARM64 · current registry tags identified by manifest digest · final filesystem. Scans read images without executing them. These snapshots are not attestations of a previously built or deployed AMI.</p><div class="scan-grid">@@SCAN_CARDS@@</div><div class="method-note"><strong>Package records are not license approvals.</strong> Missing licenses and opaque <code>sha256:</code> license entries remain unresolved. Static, stripped, vendored and frontend dependencies can be missed. Host OS, datasource plugin, fleet agent binaries and source provenance remain incomplete.</div>
<div id="package-explorer"><h3>Package explorer</h3><div class="toolbar"><input id="package-search" type="search" aria-label="Search scanned packages" placeholder="Search package, version, license or PURL…"><select id="package-image" aria-label="Filter image"><option value="">All scanned images</option></select><button id="package-clear" type="button">Clear</button></div><p class="count" id="package-count" role="status" aria-live="polite"></p><div class="table-scroll"><table class="package-table"><thead><tr><th scope="col">Image</th><th scope="col">Package / identifier</th><th scope="col">Version</th><th scope="col">Scanner license evidence</th></tr></thead><tbody id="package-body"></tbody></table></div><div class="pager"><span class="count" id="package-page"></span><div class="pager-controls"><button id="previous" type="button">← Previous</button><button id="next" type="button">Next →</button></div></div></div>
<details><summary>Scope, regeneration & release-specific SBOM instructions</summary><div class="prose">@@SBOM_GUIDE@@</div></details></section>
<section class="section" id="downloads"><div class="section-head"><span class="section-number">06</span><h2>Evidence files</h2></div><p class="intro">Original machine-readable artifacts remain in repository. Embedded inventory and package explorer work offline; downloads use paths relative to this report.</p><div class="downloads">@@DOWNLOADS@@</div></section>
<footer>Ironlog · Reviewed 03 November 2026 · Public-source assessment and partial software inventory.<br>No FOCI clearance, full FOSS certification, vulnerability clearance or production artifact attestation is implied. No runtime or cloud infrastructure changed.</footer>
</main><noscript><p style="margin:24px">JavaScript disabled: full assessment, infrastructure BOM and evidence links remain available. Enable JavaScript for searchable inventory and package explorer.</p></noscript>
<script id="report-data" type="application/json">@@DATA@@</script>
<script>
'use strict';
const data=JSON.parse(document.getElementById('report-data').textContent), $=id=>document.getElementById(id);
const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pretty=value=>value.replaceAll('-',' ').replaceAll('_',' ').toLowerCase();
function options(id,values){for(const v of [...new Set(values)].sort()){const o=document.createElement('option');o.value=v;o.textContent=pretty(v);$(id).append(o);}}
options('bom-category',data.components.map(c=>c.category));options('package-image',data.packages.map(p=>p.image));
function renderBom(){const q=$('bom-search').value.trim().toLowerCase(),cat=$('bom-category').value;const items=data.components.filter(c=>(!cat||c.category===cat)&&JSON.stringify(c).toLowerCase().includes(q));$('bom-count').textContent=`${items.length} of ${data.components.length} declared components`;
$('bom-body').innerHTML=items.length?items.map(c=>`<tr><td>${esc(c.name)}${c.image?`<br><code>${esc(c.image)}</code>`:''}</td><td>${esc(c.version||'Unresolved')}</td><td>${esc(pretty(c.category))}<br><span class="pill ${c.review_color||(c.license_expression?'blue':'amber')}">${esc(c.license_expression||'License unresolved')}${c.license_review_status==='ACCEPTED_FOR_OWNER_OPERATED_USE'?' · Accepted for intended use':''}</span></td><td>${esc(c.supplier)}<br><small>${esc(pretty(c.foci_status))}</small></td><td>${esc(c.notes)}<br><small>Source: ${c.source_paths.map(esc).join(' · ')}</small></td></tr>`).join(''):'<tr><td colspan="5">No matching components. Clear filters to see full inventory.</td></tr>';}
let packagePage=0;const pageSize=50;
function renderPackages(){const q=$('package-search').value.trim().toLowerCase(),image=$('package-image').value;const items=data.packages.filter(p=>(!image||p.image===image)&&JSON.stringify(p).toLowerCase().includes(q));const pages=Math.max(1,Math.ceil(items.length/pageSize));packagePage=Math.min(packagePage,pages-1);const start=packagePage*pageSize,slice=items.slice(start,start+pageSize);
$('package-count').textContent=`${items.length.toLocaleString()} of ${data.packages.length.toLocaleString()} package records · occurrence count across images`;
$('package-body').innerHTML=slice.length?slice.map(p=>`<tr><td>${esc(pretty(p.image))}</td><td>${esc(p.name)}${p.purl?`<br><code>${esc(p.purl)}</code>`:''}</td><td>${esc(p.version)}</td><td>${p.license.startsWith('sha256:')?'Unresolved license text hash<br><code>'+esc(p.license)+'</code>':esc(p.license)}</td></tr>`).join(''):'<tr><td colspan="4">No matching packages. Clear filters to restore results.</td></tr>';
$('package-page').textContent=items.length?`${start+1}–${Math.min(start+pageSize,items.length)} · Page ${packagePage+1} of ${pages}`:'0 results';$('previous').disabled=packagePage===0;$('next').disabled=packagePage>=pages-1;}
for(const id of ['bom-search','bom-category'])$(id).addEventListener('input',renderBom);
for(const id of ['package-search','package-image'])$(id).addEventListener('input',()=>{packagePage=0;renderPackages()});
$('bom-clear').addEventListener('click',()=>{$('bom-search').value='';$('bom-category').value='';renderBom()});
$('package-clear').addEventListener('click',()=>{$('package-search').value='';$('package-image').value='';packagePage=0;renderPackages()});
$('previous').addEventListener('click',()=>{packagePage--;renderPackages()});$('next').addEventListener('click',()=>{packagePage++;renderPackages()});
$('print-report').addEventListener('click',()=>{document.querySelectorAll('details').forEach(d=>d.open=true);window.print()});
renderBom();renderPackages();
</script></body></html>'''

values = {
    "DIAGRAM": diagram,
    "COMPONENT_COUNT": str(len(inventory["components"])),
    "SCANNED_IMAGE_COUNT": str(sum(r["status"] == "success" for r in scans["results"])),
    "RUNTIME_IMAGE_COUNT": str(sum(c["category"] == "runtime" and bool(c["image"]) for c in inventory["components"])),
    "PACKAGE_COUNT": f"{len(packages):,}",
    "REVIEW": render_document("docs/foss-foci-assessment.md", "review"),
    "BOM": render_document("docs/bom.md", "bom"),
    "SBOM_GUIDE": render_document("sbom/README.md", "guide"),
    "SCAN_CARDS": "".join(scan_cards),
    "DOWNLOADS": downloads,
    "DATA": json.dumps({"components": inventory["components"], "packages": packages}, ensure_ascii=True, separators=(",", ":")).replace("<", "\\u003c"),
}
for key, value in values.items():
    template = template.replace("@@" + key + "@@", value)
assert not re.search(r"@@[A-Z_]+@@", template)
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
OUTPUT.write_text(template, encoding="utf-8")
print(f"Created {OUTPUT}: {len(inventory['components'])} components, {len(packages)} package records, {OUTPUT.stat().st_size:,} bytes")
