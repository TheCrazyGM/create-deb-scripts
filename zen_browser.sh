#!/bin/bash
# This script fetches the latest Zen Browser release from GitHub and builds a Debian package.
set -euo pipefail

# Logging helpers
die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }

trap 'rm -rf zen "$TARBALL" "$BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
REPO="zen-browser/desktop"
GH_API="https://api.github.com"
PACKAGE_NAME="zen-browser"
ARCH="$(dpkg --print-architecture)"
BUILD_DIR=""
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
    TARBALL="zen.linux-x86_64.tar.xz"
    ;;
  arm64)
    TARBALL="zen.linux-aarch64.tar.xz"
    ;;
  *)
    echo "Error: Unsupported architecture: $ARCH" >&2
    exit 1
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
  echo "Error: No version found." >&2
  exit 1
fi

# Strip leading 'v' if present for Debian version compliance
DEB_VERSION="$VERSION"
if [[ "$DEB_VERSION" =~ ^v[0-9] ]]; then
  DEB_VERSION="${DEB_VERSION#v}"
fi

TARBALL_URL=$(echo "$release_data" | jq -r '.assets[] | select(.name == "'"$TARBALL"'") | .browser_download_url')
if [ -z "$TARBALL_URL" ]; then
  die "Tarball $TARBALL not found in latest release."
fi

info "Latest version: $VERSION"
info "Downloading $TARBALL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
# Set up build variables
BUILD_DIR="${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/zen"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"
ICON_BASE="$BUILD_DIR/usr/share/icons/hicolor"

# === CLEAN UP OLD BUILDS ===
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
info "Extracting tarball..."
tar -xf "$TARBALL"
mv zen/* "$INSTALL_DIR"

# === CREATE EXECUTABLE WRAPPER ===
info "Creating wrapper script..."
cat <<EOF >"$BIN_DIR/zen"
#!/bin/bash
/opt/zen/zen "\$@"
EOF
chmod +x "$BIN_DIR/zen"

# === INSTALL ICONS (prefer bundled hicolor, fallback to defaults) ===
info "Installing icons..."
if [ -d "$INSTALL_DIR/share/icons" ]; then
  mkdir -p "$BUILD_DIR/usr/share"
  cp -r "$INSTALL_DIR/share/icons" "$BUILD_DIR/usr/share/" || true
else
  echo "Warning: Bundled hicolor icons not found; falling back to copying default PNGs." >&2
  for size in 16 32 48 64 128; do
    mkdir -p "$ICON_BASE/${size}x${size}/apps"
    if [ -f "$INSTALL_DIR/browser/chrome/icons/default/default${size}.png" ]; then
      cp "$INSTALL_DIR/browser/chrome/icons/default/default${size}.png" \
        "$ICON_BASE/${size}x${size}/apps/zen.png"
    fi
  done
fi

# === CREATE .desktop FILE ===
info "Creating .desktop file..."
cat <<EOF >"$DESKTOP_DIR/zen.desktop"
[Desktop Entry]
Name=Zen Browser
Comment=Experience tranquillity while browsing the web without people tracking you!
Keywords=web;browser;internet
Exec=/opt/zen/zen %u
Icon=zen
Terminal=false
StartupNotify=true
StartupWMClass=zen
NoDisplay=false
Type=Application
MimeType=text/html;text/xml;application/xhtml+xml;application/vnd.mozilla.xul+xml;text/mml;x-scheme-handler/http;x-scheme-handler/https;
Categories=Network;WebBrowser;
Actions=new-window;new-private-window;profile-manager-window;

[Desktop Action new-window]
Name=Open a New Window
Exec=/opt/zen/zen --new-window %u

[Desktop Action new-private-window]
Name=Open a New Private Window
Exec=/opt/zen/zen --private-window %u

[Desktop Action profile-manager-window]
Name=Open the Profile Manager
Exec=/opt/zen/zen --ProfileManager
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
Description: Zen Browser - A privacy-focused browser that helps you browse in peace.
EOF

# === POSTINST TO UPDATE ICON CACHE ===
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

# === FINAL CLEANUP ===
info "Final cleanup..."
rm -rf zen "$BUILD_DIR" "$TARBALL"

echo "Done! Output: ${OUTDIR}/${BUILD_DIR}.deb"
