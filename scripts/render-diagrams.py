"""Rebuild repository diagrams through the hosted Drawbridge MCP server.

python scripts/render-diagrams.py [--name ironlog-architecture] [--output-root PATH]
Topology comes from DOT; presentation changes use Drawbridge edit_diagram.
Returned draw.io, SVG and PNG documents are saved without manual XML edits.
"""
import argparse
import base64
import json
from pathlib import Path
import urllib.request
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parents[1]
ENDPOINT = "https://drawbridge.fortiknight.com/mcp"
NAMES = ("ironlog-architecture", "ironlog-ingestion", "ironlog-access-audit")


def call(name, arguments):
    payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
               "params": {"name": name, "arguments": arguments}}
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"})
    with urllib.request.urlopen(request, timeout=90) as response:
        reply = json.load(response)
    if "error" in reply or reply.get("result", {}).get("isError"):
        raise RuntimeError(str(reply)[:1500])
    return reply["result"]["content"]


def text_document(content, prefix):
    return next(item["text"] for item in content
                if item.get("type") == "text" and item["text"].lstrip().startswith(prefix))


def render(name, output_root):
    source_dir = REPO / "docs/images" / name
    source = (source_dir / f"{name}.dot").read_text(encoding="utf-8")
    layout = json.loads((source_dir / f"{name}.layout.json").read_text(encoding="utf-8"))
    validation = json.loads(text_document(call("validate", {"source": source}), "{"))
    if validation.get("problems"):
        raise RuntimeError(f"{name}: {validation['problems']}")
    content = call("create_diagram", {"source": source, "kind": "drawio",
                                     "theme": "light", "name": name})
    # Refuse adjusted/skipped topology rather than silently publishing it.
    for item in content:
        if item.get("type") == "text" and "note:" in item["text"].lower():
            raise RuntimeError(item["text"][:1500])
    document = text_document(content, "<mxfile")
    description = json.loads(text_document(call("describe", {"document": document}), "{"))
    # Layout keys use the first line of a multi-line label (role captions follow).
    ids = {device["label"].split(chr(10))[0]: device["id"]
           for page in description["pages"] for device in page["devices"]}
    # Zones are annotations, so describe omits them. Read their ids from XML;
    # all mutations still go through Drawbridge's public edit tool.
    for cell in ET.fromstring(document).iter("mxCell"):
        if "drawbridge=zone;" in cell.get("style", ""):
            ids[cell.get("value").split(chr(10))[0]] = cell.get("id")
    ops = [{"op": "update_node", "id": ids[label], **properties}
           for label, properties in layout.items()]
    document = text_document(call("edit_diagram", {
        "document": document, "ops": ops, "kind": "drawio",
        "theme": "light", "name": name}), "<mxfile")
    outputs = {"drawio": document.encode()}
    for kind in ("svg", "png", "describe.json"):
        content = call("export", {"document": document, "kind": kind,
                                  "theme": "light", "name": name})
        if kind == "png":
            outputs[kind] = base64.b64decode(next(
                item["data"] for item in content if item["type"] == "image"))
        else:
            outputs[kind] = text_document(content, ("<?xml", "<svg", "{")).encode()
    final = json.loads(outputs["describe.json"])
    original_links = {(link["from"]["label"], link["to"]["label"], link.get("label", ""))
                      for page in description["pages"] for link in page["links"]}
    final_links = {(link["from"]["label"], link["to"]["label"], link.get("label", ""))
                   for page in final["pages"] for link in page["links"]}
    if original_links != final_links or final["counts"] != description["counts"]:
        raise RuntimeError(f"{name}: topology changed during presentation edits")
    if not outputs["png"].startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError(f"{name}: invalid PNG")
    ET.fromstring(outputs["drawio"])
    ET.fromstring(outputs["svg"])
    destination = output_root / name
    destination.mkdir(parents=True, exist_ok=True)
    for kind, data in outputs.items():
        (destination / f"{name}.{kind}").write_bytes(data)
    print(f"{name}: {final['counts']['devices']} devices, "
          f"{final['counts']['links']} links; drawio/SVG/PNG/round-trip verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", choices=NAMES)
    parser.add_argument("--output-root", type=Path, default=REPO / "docs/images")
    args = parser.parse_args()
    for diagram in (args.name,) if args.name else NAMES:
        render(diagram, args.output_root)
