#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${1:-$HOME/.local/bin}"
PRODUCTS=(ap ap-archive astrokit-mcp)

# ── Colours ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  ✓${RESET}  $*"; }
warn() { echo -e "${YELLOW}  !${RESET}  $*"; }
die()  { echo -e "${RED}  ✗${RESET}  $*" >&2; exit 1; }

echo ""
echo "  AstrophotoKit installer"
echo "  Install directory: $INSTALL_DIR"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────
echo "Checking prerequisites..."

command -v swift &>/dev/null \
  || die "Swift not found. Install Xcode or the Swift toolchain from swift.org."
ok "Swift $(swift --version 2>&1 | head -1 | sed 's/Apple Swift version //')"

# cfitsio can be installed via Homebrew, MacPorts, or system packages.
# Check for the header file since pkg-config may not be on PATH for Homebrew.
_cfitsio_h=$(find /opt/homebrew /opt/local /usr/local /usr -name "fitsio.h" -print -quit 2>/dev/null || true)
if [[ -n "$_cfitsio_h" ]]; then
  ok "cfitsio found (${_cfitsio_h%/include/fitsio.h})"
elif pkg-config --exists cfitsio 2>/dev/null; then
  ok "cfitsio $(pkg-config --modversion cfitsio)"
else
  die "cfitsio not found. Install it with:  brew install cfitsio  or  sudo port install cfitsio"
fi

# ── Build ────────────────────────────────────────────────────────────────────
echo ""
echo "Building release binaries..."
swift build -c release --product ap --product ap-archive --product astrokit-mcp \
  || die "Build failed. See output above for details."
ok "Build complete"

# ── Install ──────────────────────────────────────────────────────────────────
echo ""
echo "Installing to ${INSTALL_DIR}..."

mkdir -p "$INSTALL_DIR"

for product in "${PRODUCTS[@]}"; do
  src=".build/release/$product"
  dst="$INSTALL_DIR/$product"
  [[ -f "$src" ]] || die "Binary not found: $src"
  cp "$src" "$dst"
  chmod +x "$dst"
  ok "Installed $product → $dst"
done

# ── PATH check ───────────────────────────────────────────────────────────────
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  warn "$INSTALL_DIR is not in your PATH."
  warn "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
  warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "  Done. Try:  ap --help  /  ap-archive --help"
echo ""
