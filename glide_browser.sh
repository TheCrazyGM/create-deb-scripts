#!/bin/bash
# This script fetches the latest Glide Browser release from GitHub and builds a Debian package.
set -euo pipefail

# Logging helpers
die() {
  echo "[ERROR] $*" >&2
  exit 1
}
info() { echo "[INFO]  $*"; }

trap 'rm -rf glide "$TARBALL" "$BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
REPO="glide-browser/glide"
GH_API="https://api.github.com"
PACKAGE_NAME="glide-browser"
ARCH="$(dpkg --print-architecture)"
BUILD_DIR=""
TARBALL=""
OUTDIR=$(pwd)

# === CHECK DEPENDENCIES ===
command_exist() { command -v "$1" >/dev/null 2>&1; }
for dep in curl jq tar dpkg-deb; do
  if ! command_exist "$dep"; then
    die "$dep is not installed."
  fi
done

# === MAP ARCH TO TARBALL NAME ===
case "$ARCH" in
amd64)
  TARBALL="glide.linux-x86_64.tar.xz"
  ;;
arm64)
  TARBALL="glide.linux-aarch64.tar.xz"
  ;;
*)
  die "Unsupported architecture: $ARCH"
  ;;
esac

# === FETCH LATEST RELEASE ===
info "Fetching latest release from $REPO..."
release_data=$(curl -s "$GH_API/repos/$REPO/releases/latest")
if [ -z "$release_data" ] || echo "$release_data" | jq -e '.message' >/dev/null; then
  die "Failed to fetch release data."
fi

# === EXTRACT VERSION AND TARBALL URL ===
VERSION=$(echo "$release_data" | jq -r '.tag_name')
if [ "$VERSION" = "null" ] || [ -z "$VERSION" ]; then
  die "No version found."
fi

DEB_VERSION="$VERSION"
if [[ "$DEB_VERSION" =~ ^v[0-9] ]]; then
  DEB_VERSION="${DEB_VERSION#v}"
fi

TARBALL_URL=$(echo "$release_data" | jq -r '.assets[] | select(.name == "'"$TARBALL"'") | .browser_download_url')
if [ -z "$TARBALL_URL" ] || [ "$TARBALL_URL" = "null" ]; then
  die "Tarball $TARBALL not found in latest release."
fi

info "Latest version: $VERSION"
info "Downloading $TARBALL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
BUILD_DIR="${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/glide"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"
ICON_BASE="$BUILD_DIR/usr/share/icons/hicolor"

# === CLEAN UP OLD BUILDS ===
rm -rf "$BUILD_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
info "Extracting tarball..."
tar -xf "$TARBALL"
if [ ! -d glide ]; then
  die "Expected 'glide' directory after extraction."
fi
rm -rf "$INSTALL_DIR"
mv glide "$INSTALL_DIR"

# === CREATE EXECUTABLE WRAPPER ===
info "Creating wrapper script..."
cat <<'EOF' >"$BIN_DIR/glide"
#!/bin/bash
exec /opt/glide/glide "$@"
EOF
chmod +x "$BIN_DIR/glide"

# === INSTALL ICONS ===
info "Installing icons..."
mkdir -p "$ICON_BASE"
for size in 16 32 48 64 128; do
  src="$INSTALL_DIR/browser/chrome/icons/default/default${size}.png"
  if [ -f "$src" ]; then
    mkdir -p "$ICON_BASE/${size}x${size}/apps"
    cp "$src" "$ICON_BASE/${size}x${size}/apps/glide.png"
  fi
done

# === CREATE .desktop FILE ===
info "Creating .desktop file..."
cat <<'EOF' >"$DESKTOP_DIR/glide.desktop"
[Desktop Entry]
Name=Glide Browser
Comment=Lighter, faster browsing with Glide
Keywords=web;browser;internet
Exec=/opt/glide/glide %u
Icon=glide
Terminal=false
StartupNotify=true
StartupWMClass=glide
NoDisplay=false
Type=Application
MimeType=text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;text/mml;x-scheme-handler/http;x-scheme-handler/https;
Categories=Network;WebBrowser;
EOF

# === CREATE DEBIAN CONTROL FILE ===
info "Creating control file..."
mkdir -p "$BUILD_DIR/DEBIAN"
cat <<EOF >"$BUILD_DIR/DEBIAN/control"
Package: $PACKAGE_NAME
Version: $DEB_VERSION
Section: web
Priority: optional
Architecture: $ARCH
Maintainer: Michael Garcia <thecrazygm@gmail.com>
Description: Glide Browser - A lightweight Firefox-based browser.
EOF

# === POSTINST TO UPDATE CACHES ===
cat <<'EOF' >"$BUILD_DIR/DEBIAN/postinst"
#!/bin/bash
set -e
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor
fi
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v xdg-desktop-menu &>/dev/null; then
  xdg-desktop-menu forceupdate || true
fi
EOF
chmod +x "$BUILD_DIR/DEBIAN/postinst"

chmod -R a+rX "$BUILD_DIR"

# === BUILD THE DEB PACKAGE ===
info "Building .deb package..."
dpkg-deb --build --root-owner-group "$BUILD_DIR"

info "Final cleanup..."
rm -rf "$BUILD_DIR" "$TARBALL"

echo "Done! Output: ${OUTDIR}/${BUILD_DIR}.deb"
