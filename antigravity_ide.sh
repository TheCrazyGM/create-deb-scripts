#!/bin/bash
# This script fetches the latest Google Antigravity IDE release and builds a Debian package.
set -euo pipefail

# Logging helpers
die() {
  echo "[ERROR] $*" >&2
  exit 1
}
info() { echo "[INFO]  $*"; }

# Cleanup on exit
trap 'rm -rf "Antigravity IDE"* "$TARBALL" "$BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
PACKAGE_NAME="antigravity-ide"
ARCH="$(dpkg --print-architecture)"
BUILD_DIR=""
OUTDIR=$(pwd)
TARBALL="antigravity_ide.tar.gz"

RELEASES_PAGE_URL="https://antigravity.google/releases"
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
info "Fetching releases page to find JavaScript bundle..."
html_content=$(curl -sL --compressed "$RELEASES_PAGE_URL")
MAIN_JS=$(echo "$html_content" | grep -oE 'main-[a-zA-Z0-9]+\.js' | head -n 1)

if [ -z "$MAIN_JS" ]; then
  die "Failed to locate main JavaScript bundle on the releases page."
fi

info "Fetching JavaScript bundle: $MAIN_JS..."
js_content=$(curl -sL --compressed "$BASE_URL/$MAIN_JS")

# Try to extract API URL from JS bundle
API_URL=$(echo "$js_content" | grep -oE 'https://antigravity-ide-auto-updater-[0-9a-zA-Z.-]+\.run\.app/releases' | head -n 1 || true)

TARBALL_URL=""
VERSION=""

if [ -n "$API_URL" ]; then
  info "Querying auto-updater API: $API_URL..."
  api_response=$(curl -sL "$API_URL" || true)
  if [ -n "$api_response" ]; then
    VERSION_VAL=$(echo "$api_response" | jq -r '.[0].version' 2>/dev/null || true)
    EXEC_ID=$(echo "$api_response" | jq -r '.[0].execution_id' 2>/dev/null || true)
    if [ -n "$VERSION_VAL" ] && [ "$VERSION_VAL" != "null" ] && [ -n "$EXEC_ID" ] && [ "$EXEC_ID" != "null" ]; then
      VERSION="${VERSION_VAL}-${EXEC_ID}"
      TARBALL_URL="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${VERSION}/${ARCH_SUFFIX}/Antigravity%20IDE.tar.gz"
      info "Found version $VERSION from API."
    fi
  fi
fi

if [ -z "$TARBALL_URL" ]; then
  info "Fallback: locating download URL directly in JavaScript bundle..."
  TARBALL_URL=$(echo "$js_content" | grep -oE "https://edgedl\.me\.gvt1\.com/edgedl/release2/[0-9a-zA-Z]+/antigravity/stable/[0-9a-zA-Z.-]+/${ARCH_SUFFIX}/Antigravity%20IDE\.tar\.gz" | head -n 1 || true)
  if [ -z "$TARBALL_URL" ]; then
    die "Tarball URL for $ARCH ($ARCH_SUFFIX) not found."
  fi
  VERSION=$(echo "$TARBALL_URL" | sed -n "s|.*/stable/\([^/]*\)/${ARCH_SUFFIX}/.*|\1|p")
  if [ -z "$VERSION" ]; then
    die "Failed to extract version from URL: $TARBALL_URL"
  fi
fi

DEB_VERSION="$VERSION"

info "Latest version: $DEB_VERSION"
info "Downloading $TARBALL_URL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
# Set up build variables
BUILD_DIR="${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/google/antigravity-ide"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"

# === CLEAN UP OLD BUILDS ===
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/opt/google" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
info "Extracting tarball..."
tar -xf "$TARBALL"

# Find extracted folder (e.g. Antigravity IDE or similar)
EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "Antigravity IDE*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ]; then
  die "Could not find extracted Antigravity IDE folder"
fi

info "Moving files from $EXTRACTED_DIR to $INSTALL_DIR..."
mv "$EXTRACTED_DIR" "$INSTALL_DIR"

# === CREATE EXECUTABLE WRAPPER ===
info "Creating wrapper script..."
cat <<EOF >"$BIN_DIR/antigravity-ide"
#!/bin/bash
exec /opt/google/antigravity-ide/bin/antigravity-ide "\$@"
EOF
chmod +x "$BIN_DIR/antigravity-ide"

# === INSTALL ICONS ===
info "Installing icons..."
ICON_TARGET_DIR="$BUILD_DIR/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$ICON_TARGET_DIR"
if [ -f "$INSTALL_DIR/resources/app/out/media/jetski-logo-black.svg" ]; then
  cp "$INSTALL_DIR/resources/app/out/media/jetski-logo-black.svg" "$ICON_TARGET_DIR/antigravity-ide.svg"
elif [ -f "$INSTALL_DIR/resources/app/out/media/jetski-logo-white.svg" ]; then
  cp "$INSTALL_DIR/resources/app/out/media/jetski-logo-white.svg" "$ICON_TARGET_DIR/antigravity-ide.svg"
elif [ -f "$INSTALL_DIR/resources/app/out/media/code-icon.svg" ]; then
  cp "$INSTALL_DIR/resources/app/out/media/code-icon.svg" "$ICON_TARGET_DIR/antigravity-ide.svg"
else
  echo "Warning: Icon file not found in package; desktop icon may be missing." >&2
fi

# === CREATE .desktop FILE ===
info "Creating .desktop file..."
cat <<EOF >"$DESKTOP_DIR/antigravity-ide.desktop"
[Desktop Entry]
Name=Antigravity IDE
Comment=Build the new way - Google Antigravity IDE
Exec=/opt/google/antigravity-ide/bin/antigravity-ide %u
Icon=antigravity-ide
Terminal=false
StartupNotify=true
StartupWMClass=antigravity-ide
NoDisplay=false
Type=Application
Categories=Development;IDE;
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
Description: Google Antigravity IDE - Build the new way. IDE and compiler tools.
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
