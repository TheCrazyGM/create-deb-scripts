#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Neovim (git)
# - Clones neovim, builds with CMake, stages install, and assembles a .deb
# - Uses bundled third-party deps by default to avoid system detection issues (luv, etc.)

# Utilities
die() {
  echo "[ERROR] $*" >&2
  exit 1
}
info() { echo "[INFO]  $*"; }

# makenvim.sh - Build Neovim Debian package from git

OUTDIR=$(pwd)

# Temp dir
TMPDIR=$(mktemp -d -t makenvim.XXXXXX)
cleanup() {
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT INT TERM
info "Using temp dir: ${TMPDIR}"

# Check required tools
for cmd in git cmake make dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

# Clone repo
git clone --depth=1 https://github.com/neovim/neovim.git "$TMPDIR/neovim"
cd "$TMPDIR/neovim"

# Compute version
PKGVER=$(git describe --always | sed -e 's:-:.:g' -e 's:v::')
COMMITS=$(git rev-list --count HEAD)
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's:-:.:g' | sed 's:_:.:g')
FULLVER="${COMMITS}.${PKGVER}.${DATE}"
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export SOURCE_DATE_EPOCH

# Package metadata for control file
PKGNAME="neovim-git"
PKGDESC="Vim-fork focused on extensibility and usability"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://neovim.io/"
ARCH="$(dpkg --print-architecture)"
# Runtime deps mapped to Debian package names (adjust for t64 transitions if needed)
DEPENDS="libluajit-5.1-2, libluajit-5.1-common, libmsgpack-c2, libtermkey1, libunibilium4, libvterm0, lua-luv"

# Prepare
rm -rf build .builds .deps

# Build using Neovim's top-level Makefile (handles third-party like luv correctly)
# Prefer building bundled third-party libraries (luv, libvterm, unibilium, etc.)
# to avoid system-detection issues. Allow override via USE_BUNDLED=0.
CMAKE_FLAGS=(-DCMAKE_INSTALL_PREFIX=/usr)
if [[ "$(dpkg --print-architecture)" = "arm64" ]]; then
  CMAKE_FLAGS+=(-DENABLE_JEMALLOC=FALSE)
fi
CMAKE_EXTRA_FLAGS="${CMAKE_FLAGS[*]}" CMAKE_BUILD_TYPE=Release make -j "$(nproc)"

# Install to pkg dir
PKGDIR="$TMPDIR/pkg"
mkdir -p "$PKGDIR/usr"
make install DESTDIR="$PKGDIR"

# Install extras
install -Dm644 LICENSE.txt "$PKGDIR/usr/share/doc/neovim/copyright"
install -Dm644 runtime/nvim.desktop "$PKGDIR/usr/share/applications/nvim.desktop"
install -Dm644 runtime/nvim.png "$PKGDIR/usr/share/pixmaps/nvim.png"
mkdir -p "$PKGDIR/usr/share/vim"
mkdir -p "$PKGDIR/etc/xdg/nvim"
echo '" This commented line makes apt-installed global vim packages work.' >"$PKGDIR/etc/xdg/nvim/sysinit.vim"
echo "set runtimepath+=/usr/share/vim/vimfiles" >"$PKGDIR/usr/share/nvim/debian.vim"
echo "source /usr/share/nvim/debian.vim" >>"$PKGDIR/etc/xdg/nvim/sysinit.vim"

# Create DEBIAN dir
mkdir -p "$PKGDIR/DEBIAN"

# Generate control file
cat >"$PKGDIR/DEBIAN/control" <<EOF
Package: $PKGNAME
Version: $FULLVER
Section: editors
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Description: $PKGDESC
Homepage: $URL
Depends: $DEPENDS
EOF

# Post-install to refresh icon and desktop caches
cat <<'EOF' >"$PKGDIR/DEBIAN/postinst"
#!/bin/bash
set -e
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v xdg-desktop-menu &>/dev/null; then
  xdg-desktop-menu forceupdate || true
fi
EOF
chmod +x "$PKGDIR/DEBIAN/postinst"

# Normalize permissions for packaging
find "$PKGDIR" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "$PKGDIR"
chmod 0755 "$PKGDIR/DEBIAN" || true
chmod 0644 "$PKGDIR/DEBIAN/control"

# Build the .deb using dpkg-deb to avoid tar/ar quirks
DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKGDIR" "${OUTDIR}/${DEB_NAME}"

echo "Done! Output: ${OUTDIR}/${DEB_NAME}"
