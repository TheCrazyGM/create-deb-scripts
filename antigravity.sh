#!/bin/bash
# This script fetches the latest Google Antigravity release and builds a Debian package.
set -euo pipefail

# Logging helpers
die() {
  echo "[ERROR] $*" >&2
  exit 1
}
info() { echo "[INFO]  $*"; }

# Cleanup on exit
trap 'rm -rf Antigravity-* "$TARBALL" "$BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
PACKAGE_NAME="antigravity"
ARCH="$(dpkg --print-architecture)"
BUILD_DIR=""
OUTDIR=$(pwd)
TARBALL="antigravity.tar.gz"

DOWNLOAD_PAGE_URL="https://antigravity.google/download"
BASE_URL="https://antigravity.google"

# === CHECK DEPENDENCIES ===
command_exist() { command -v "$1" >/dev/null 2>&1; }
for dep in curl jq tar dpkg-deb; do
  if ! command_exist "$dep"; then
    die "$dep is not installed."
  fi
done

# === MAP ARCH TO URL SEGMENT ===
case "$ARCH" in
amd64)
  ARCH_SUFFIX="linux-x64"
  ;;
arm64)
  ARCH_SUFFIX="linux-arm"
  ;;
*)
  echo "Error: Unsupported architecture: $ARCH" >&2
  exit 1
  ;;
esac

# === DYNAMICALLY FETCH LATEST TARBALL URL ===
info "Fetching download page to find JavaScript bundle..."
html_content=$(curl -sL --compressed "$DOWNLOAD_PAGE_URL")
MAIN_JS=$(echo "$html_content" | grep -oE 'main-[a-zA-Z0-9]+\.js' | head -n 1)

if [ -z "$MAIN_JS" ]; then
  die "Failed to locate main JavaScript bundle on the download page."
fi

info "Fetching JavaScript bundle: $MAIN_JS..."
js_content=$(curl -sL --compressed "$BASE_URL/$MAIN_JS")

info "Locating download URL for architecture: $ARCH ($ARCH_SUFFIX)..."
TARBALL_URL=$(echo "$js_content" | grep -oE "https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[0-9a-zA-Z.-]+/${ARCH_SUFFIX}/Antigravity\.tar\.gz" | head -n 1)

if [ -z "$TARBALL_URL" ]; then
  die "Tarball URL for $ARCH ($ARCH_SUFFIX) not found in JavaScript bundle."
fi

# === EXTRACT VERSION ===
VERSION=$(echo "$TARBALL_URL" | sed -n "s|.*/antigravity-hub/\([^/]*\)/${ARCH_SUFFIX}/.*|\1|p")
if [ -z "$VERSION" ]; then
  die "Failed to extract version from URL: $TARBALL_URL"
fi

DEB_VERSION="$VERSION"

info "Latest version: $DEB_VERSION"
info "Downloading $TARBALL_URL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
# Set up build variables
BUILD_DIR="${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/google/antigravity"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"

# === CLEAN UP OLD BUILDS ===
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
info "Extracting tarball..."
tar -xf "$TARBALL"

# Find extracted folder (e.g. Antigravity-x64 or Antigravity-arm)
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "Antigravity-*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ] && [ -d "Antigravity" ]; then
  EXTRACTED_DIR="Antigravity"
fi
if [ -z "$EXTRACTED_DIR" ]; then
  die "Could not find extracted Antigravity folder"
fi

info "Moving files from $EXTRACTED_DIR to $INSTALL_DIR..."
mv "$EXTRACTED_DIR"/* "$INSTALL_DIR/"
rm -rf "$EXTRACTED_DIR"

# === CREATE EXECUTABLE WRAPPER ===
info "Creating wrapper script..."
cat <<EOF >"$BIN_DIR/antigravity"
#!/bin/bash
exec /opt/google/antigravity/antigravity "\$@"
EOF
chmod +x "$BIN_DIR/antigravity"

# === CREATE .desktop FILE ===
info "Creating .desktop file..."
cat <<EOF >"$DESKTOP_DIR/antigravity.desktop"
[Desktop Entry]
Name=Antigravity
Comment=Build the new way - Google Antigravity Hub
Exec=/opt/google/antigravity/antigravity %u
Icon=antigravity
Terminal=false
StartupNotify=true
StartupWMClass=antigravity
NoDisplay=false
Type=Application
Categories=Development;
EOF

# === CREATE DEBIAN CONTROL FILE ===
info "Creating control file..."
mkdir -p "$BUILD_DIR/DEBIAN"
cat <<EOF >"$BUILD_DIR/DEBIAN/control"
Package: $PACKAGE_NAME
Version: $DEB_VERSION
Section: devel
Priority: optional
Architecture: $ARCH
Maintainer: Michael Garcia <thecrazygm@gmail.com>
Description: Google Antigravity - Build the new way. Hub and execution runtime.
EOF

# === POSTINST TO UPDATE DATABASES ===
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
rm -rf "$BUILD_DIR" "$TARBALL"

echo "Done! Output: ${OUTDIR}/${PACKAGE_NAME}_${DEB_VERSION}.deb"
