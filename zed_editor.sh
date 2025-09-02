#!/bin/bash
# This script fetches the latest Zed Editor release from GitHub and builds a Debian package.
set -euo pipefail

trap 'rm -rf zed.app "$TARBALL" "$BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
REPO="zed-industries/zed"
GH_API="https://api.github.com"
PACKAGE_NAME="zed-editor"
ARCH="amd64"
TARBALL="zed-linux-x86_64.tar.gz"
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
# Strip leading 'v' if present for Debian version compliance
DEB_VERSION="$VERSION"
if [[ "$DEB_VERSION" =~ ^v[0-9] ]]; then
  DEB_VERSION="${DEB_VERSION#v}"
fi
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
BUILD_DIR="${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"

# === CLEAN UP OLD BUILDS ===
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
echo "Extracting tarball..."
tar -xf "$TARBALL"
mv zed.app "$INSTALL_DIR/zed.app"

# === CREATE EXECUTABLE WRAPPER ===
echo "Creating wrapper script..."
cat <<'EOF' >"$BIN_DIR/zed"
#!/bin/bash
exec /opt/zed.app/bin/zed "$@"
EOF
chmod +x "$BIN_DIR/zed"

# === INSTALL ICONS (copy bundled hicolor if present) ===
echo "Installing icons (if available)..."
if [ -d "$INSTALL_DIR/zed.app/share/icons" ]; then
  mkdir -p "$BUILD_DIR/usr/share"
  cp -r "$INSTALL_DIR/zed.app/share/icons" "$BUILD_DIR/usr/share/" || true
else
  echo "Warning: No icons directory found in bundle; desktop icon may be missing." >&2
fi

# === INSTALL .desktop FILE (copy upstream) ===
echo "Installing .desktop file..."
if [ -f "$INSTALL_DIR/zed.app/share/applications/zed.desktop" ]; then
  cp "$INSTALL_DIR/zed.app/share/applications/zed.desktop" "$DESKTOP_DIR/zed.desktop"
else
  echo "Warning: Upstream desktop file not found; generating a minimal one." >&2
  cat <<EOF >"$DESKTOP_DIR/zed.desktop"
[Desktop Entry]
Type=Application
Name=Zed
Exec=zed %U
Icon=zed
Categories=Utility;TextEditor;Development;IDE;
EOF
fi

# === CREATE DEBIAN CONTROL FILE ===
echo "Creating control file..."
mkdir -p "$BUILD_DIR/DEBIAN"
cat <<EOF >"$BUILD_DIR/DEBIAN/control"
Package: $PACKAGE_NAME
Version: $DEB_VERSION
Section: editors
Priority: optional
Architecture: $ARCH
Maintainer: Michael Garcia <thecrazygm@gmail.com>
Description: Zed Editor - A fast, collaborative code editor.
Depends: libc6 (>= 2.31), libglib2.0-0 (>= 2.56), libgtk-3-0 (>= 3.24), libx11-6, libxcb1, libnss3, libxss1, libasound2, libxdamage1, libxcomposite1, libxrandr2, libxtst6, ca-certificates
Recommends: libvulkan1, mesa-vulkan-drivers
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
echo "Building .deb package..."
dpkg-deb --build --root-owner-group "$BUILD_DIR"

# === FINAL CLEANUP ===
echo "Final cleanup..."
rm -rf zed.app "$BUILD_DIR" "$TARBALL"

echo "Done! Output: ${BUILD_DIR}.deb"
