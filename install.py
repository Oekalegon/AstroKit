#!/usr/bin/env python3
"""AstrophotoKit installer — builds binaries and registers the MCP server."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
RED    = "\033[0;31m"
RESET  = "\033[0m"

def ok(msg):   print(f"{GREEN}  ✓{RESET}  {msg}")
def warn(msg): print(f"{YELLOW}  !{RESET}  {msg}")
def die(msg):  print(f"{RED}  ✗{RESET}  {msg}", file=sys.stderr); sys.exit(1)

# ── Config ────────────────────────────────────────────────────────────────────
INSTALL_DIR    = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / ".local" / "bin"
PRODUCTS       = ["ap", "ap-archive", "astrokit-mcp"]
MCP_BINARY     = INSTALL_DIR / "astrokit-mcp"
MCP_SERVER_KEY = "astrokit"
MCP_ENTRY      = {"command": str(MCP_BINARY)}

WARP_MCP_CONFIG    = Path.home() / ".warp" / ".mcp.json"
CLAUDE_DESKTOP_CFG = Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
CLAUDE_CODE_CFG    = Path.home() / ".claude.json"

# ── Helpers ───────────────────────────────────────────────────────────────────
def load_json(path: Path) -> dict:
    """Load JSON from path, returning {} if missing or invalid."""
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_json(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")

def upsert_mcp_server(cfg: dict, entry: dict) -> dict:
    """Insert/update MCP_SERVER_KEY inside cfg['mcpServers'], preserving others."""
    cfg.setdefault("mcpServers", {})[MCP_SERVER_KEY] = entry
    return cfg

# ── Prerequisites ─────────────────────────────────────────────────────────────
print()
print("  AstrophotoKit installer")
print(f"  Install directory: {INSTALL_DIR}")
print()
print("Checking prerequisites...")

if not shutil.which("swift"):
    die("Swift not found. Install Xcode or the Swift toolchain from swift.org.")
result = subprocess.run(["swift", "--version"], capture_output=True, text=True)
ver = result.stdout.splitlines()[0].replace("Apple Swift version ", "") if result.stdout else "unknown"
ok(f"Swift {ver}")

# cfitsio
import glob
cfitsio_headers = (
    glob.glob("/opt/homebrew/**/fitsio.h", recursive=True)
    + glob.glob("/opt/local/**/fitsio.h", recursive=True)
    + glob.glob("/usr/local/**/fitsio.h", recursive=True)
    + glob.glob("/usr/**/fitsio.h", recursive=True)
)
if cfitsio_headers:
    ok(f"cfitsio found ({cfitsio_headers[0]})")
else:
    pkg = subprocess.run(["pkg-config", "--exists", "cfitsio"], capture_output=True)
    if pkg.returncode == 0:
        ver_r = subprocess.run(["pkg-config", "--modversion", "cfitsio"], capture_output=True, text=True)
        ok(f"cfitsio {ver_r.stdout.strip()}")
    else:
        die("cfitsio not found. Install it with:  brew install cfitsio")

# ── Build ─────────────────────────────────────────────────────────────────────
print()
print("Building release binaries...")
# Build each product separately — passing multiple --product flags to a single
# swift build invocation can silently skip products that are already up to date.
for product in PRODUCTS:
    result = subprocess.run(["swift", "build", "-c", "release", "--product", product])
    if result.returncode != 0:
        die(f"Build failed for '{product}'. See output above for details.")
ok("Build complete")

# ── Install binaries ──────────────────────────────────────────────────────────
print()
print(f"Installing to {INSTALL_DIR}...")
INSTALL_DIR.mkdir(parents=True, exist_ok=True)

for product in PRODUCTS:
    src = Path(".build") / "release" / product
    dst = INSTALL_DIR / product
    if not src.exists():
        die(f"Binary not found: {src}")
    shutil.copy2(src, dst)
    dst.chmod(0o755)
    subprocess.run(["xattr", "-d", "com.apple.quarantine", str(dst)], capture_output=True)
    subprocess.run(["codesign", "--sign", "-", "--force", str(dst)], check=True)
    ok(f"Installed {product} → {dst}")

# ── PATH check ────────────────────────────────────────────────────────────────
path_dirs = os.environ.get("PATH", "").split(":")
if str(INSTALL_DIR) not in path_dirs:
    print()
    warn(f"{INSTALL_DIR} is not in your PATH.")
    warn("Add this to your shell profile (~/.zshrc or ~/.bashrc):")
    warn(f'  export PATH="$HOME/.local/bin:$PATH"')

# ── Register MCP: Warp ───────────────────────────────────────────────────────
print()
print("Registering MCP server...")

warp_cfg = load_json(WARP_MCP_CONFIG)
warp_cfg = upsert_mcp_server(warp_cfg, MCP_ENTRY)
save_json(WARP_MCP_CONFIG, warp_cfg)
ok(f"Warp MCP registered ({WARP_MCP_CONFIG})")

# ── Register MCP: Claude Desktop ─────────────────────────────────────────────
desktop_cfg = load_json(CLAUDE_DESKTOP_CFG)
desktop_cfg = upsert_mcp_server(desktop_cfg, MCP_ENTRY)
save_json(CLAUDE_DESKTOP_CFG, desktop_cfg)
ok(f"Claude Desktop MCP registered ({CLAUDE_DESKTOP_CFG})")

# ── Register MCP: Claude Code (~/.claude.json) ───────────────────────────────
claude_cfg = load_json(CLAUDE_CODE_CFG)
claude_cfg = upsert_mcp_server(claude_cfg, {"type": "stdio", "command": str(MCP_BINARY), "args": [], "env": {}})
save_json(CLAUDE_CODE_CFG, claude_cfg)
ok(f"Claude Code MCP registered ({CLAUDE_CODE_CFG})")

# ── Done ──────────────────────────────────────────────────────────────────────
print()
print("  Done.")
print(f"  • ap --help  /  ap-archive --help  /  astrokit-mcp")
print( "  • Restart Claude Desktop and Claude Code to pick up the new MCP server.")
print( "  • In Warp: Settings → Agents → MCP servers — the server appears as 'astrokit'.")
print()
