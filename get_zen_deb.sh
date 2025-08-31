#!/bin/bash
# This script fetches the latest Zen Browser release from GitHub and builds a Debian package.
set -euo pipefail

trap 'rm -rf zen "$TARBALL" "$BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
REPO="zen-browser/desktop"
GH_API="https://api.github.com"
PACKAGE_NAME="zen-browser"
ARCH="amd64"
TARBALL="zen.linux-x86_64.tar.xz"
BUILD_DIR=""

# === CHECK DEPENDENCIES ===
command_exist() { command -v "$1" >/dev/null 2>&1; }
for dep in curl jq tar dpkg-deb; do
  if ! command_exist "$dep"; then
    echo "Error: $dep is not installed." >&2
    exit 1
  fi
done

# === FETCH LATEST RELEASE ===
echo "Fetching latest release from $REPO..."
release_data=$(curl -s "$GH_API/repos/$REPO/releases/latest")
if [ -z "$release_data" ] || echo "$release_data" | jq -e '.message' >/dev/null; then
  echo "Error: Failed to fetch release data." >&2
  exit 1
fi

# === EXTRACT VERSION AND TARBALL URL ===
VERSION=$(echo "$release_data" | jq -r '.tag_name')
if [ "$VERSION" = "null" ] || [ -z "$VERSION" ]; then
  echo "Error: No version found." >&2
  exit 1
fi

TARBALL_URL=$(echo "$release_data" | jq -r '.assets[] | select(.name == "'"$TARBALL"'") | .browser_download_url')
if [ -z "$TARBALL_URL" ]; then
  echo "Error: Tarball $TARBALL not found in latest release." >&2
  exit 1
fi

echo "Latest version: $VERSION"
echo "Downloading $TARBALL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
# Set up build variables
BUILD_DIR="${PACKAGE_NAME}_${VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/zen"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/local/share/applications"
ICON_BASE="$BUILD_DIR/usr/share/icons/hicolor"

# === CLEAN UP OLD BUILDS ===
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
echo "Extracting tarball..."
tar -xf "$TARBALL"
mv zen/* "$INSTALL_DIR"

# === CREATE EXECUTABLE WRAPPER ===
echo "Creating wrapper script..."
cat <<EOF >"$BIN_DIR/zen"
#!/bin/bash
/opt/zen/zen "\$@"
EOF
chmod +x "$BIN_DIR/zen"

# === INSTALL ICONS ===
echo "Copying icons..."
for size in 16 32 48 64 128; do
  mkdir -p "$ICON_BASE/${size}x${size}/apps"
  cp "$INSTALL_DIR/browser/chrome/icons/default/default${size}.png" \
    "$ICON_BASE/${size}x${size}/apps/zen.png"
done

# === CREATE .desktop FILE ===
echo "Creating .desktop file..."
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
echo "Creating control file..."
mkdir -p "$BUILD_DIR/DEBIAN"
cat <<EOF >"$BUILD_DIR/DEBIAN/control"
Package: $PACKAGE_NAME
Version: $VERSION
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
EOF
chmod +x "$BUILD_DIR/DEBIAN/postinst"

chmod -R a+rX "$BUILD_DIR"

# === BUILD THE DEB PACKAGE ===
echo "Building .deb package..."
dpkg-deb --build --root-owner-group "$BUILD_DIR"

# === FINAL CLEANUP ===
echo "Final cleanup..."
rm -rf zen "$BUILD_DIR" "$TARBALL"

echo "Done! Output: ${BUILD_DIR}.deb"
