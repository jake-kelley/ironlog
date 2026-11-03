"""Compatibility entry point; render every format through Drawbridge MCP."""
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[3]
subprocess.run([sys.executable, str(repo / "scripts/render-diagrams.py"),
                "--name", "ironlog-architecture"], check=True)
