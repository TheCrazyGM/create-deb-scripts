#!/bin/bash
# This script fetches the latest Google Antigravity IDE release and builds a Debian package.
set -euo pipefail

# Logging helpers
die() {
  echo "[ERROR] $*" >&2
  exit 1
}
info() { echo "[INFO]  $*"; }

# Create temporary build directory
TMP_BUILD_DIR=$(mktemp -d /tmp/antigravity-ide-build.XXXXXX)

# Cleanup on exit
trap 'rm -rf "$TMP_BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
PACKAGE_NAME="antigravity-ide"
ARCH="$(dpkg --print-architecture)"
OUTDIR=$(pwd)
TEMP_JS="$TMP_BUILD_DIR/main_js_temp.js"

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
info "Fetching download page to find latest release..."
html_content=$(curl -sL --compressed "https://antigravity.google/download" || curl -sL --compressed "https://antigravity.google/releases")

TARBALL_URL=$(echo "$html_content" | grep -oP 'https://edgedl.me.gvt1.com/edgedl/release2/[^/]+/antigravity/stable/[^/]+/'"$ARCH_SUFFIX"'/Antigravity(%20| )IDE\.tar\.gz' | head -n 1 || true)

if [ -z "$TARBALL_URL" ]; then
  # Fallback: regex search in HTML for storage/edgedl url
  TARBALL_URL=$(echo "$html_content" | grep -oE "https://edgedl\.me\.gvt1\.com/edgedl/release2/[a-zA-Z0-9]+/antigravity/stable/[0-9a-zA-Z.-]+/${ARCH_SUFFIX}/Antigravity(%20| )IDE\.tar\.gz" | head -n 1 || true)
fi

if [ -z "$TARBALL_URL" ]; then
  die "Failed to locate Antigravity IDE download URL on the website."
fi

# URL encode spaces to %20 just in case it matched with raw space
TARBALL_URL=$(echo "$TARBALL_URL" | sed 's/ /%20/g')

VERSION=$(echo "$TARBALL_URL" | grep -oP 'antigravity/stable/\K[^/]+' || true)
if [ -z "$VERSION" ]; then
  VERSION=$(echo "$TARBALL_URL" | sed -n "s|.*/stable/\([^/]*\)/${ARCH_SUFFIX}/.*|\1|p")
fi

if [ -z "$VERSION" ]; then
  die "Failed to extract version from URL: $TARBALL_URL"
fi

DEB_VERSION="$VERSION"

info "Latest version: $DEB_VERSION"

DEB_FILE="${OUTDIR}/${PACKAGE_NAME}_${DEB_VERSION}_${ARCH}.deb"
if [[ -f "$DEB_FILE" ]]; then
  info "Package $(basename "$DEB_FILE") already exists."
  if [[ -t 0 ]]; then
    read -p "Do you want to rebuild it? [y/N] " -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      info "Skipping build."
      exit 0
    fi
  else
    info "Non-interactive shell, skipping rebuild."
    exit 0
  fi
fi

TARBALL="$TMP_BUILD_DIR/antigravity_ide.tar.gz"
BUILD_DIR="$TMP_BUILD_DIR/${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/google/antigravity-ide"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"

info "Downloading $TARBALL_URL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/opt/google" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
info "Extracting tarball..."
tar -xf "$TARBALL" -C "$TMP_BUILD_DIR"

# Find extracted folder (e.g. Antigravity IDE or similar)
EXTRACTED_DIR=$(find "$TMP_BUILD_DIR" -maxdepth 2 -type d -name "Antigravity IDE*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ]; then
  die "Could not find extracted Antigravity IDE folder"
fi

info "Moving files from $EXTRACTED_DIR to $INSTALL_DIR..."
mv "$EXTRACTED_DIR" "$INSTALL_DIR"

# === SET CHROME-SANDBOX PERMISSIONS ===
if [ -f "$INSTALL_DIR/chrome-sandbox" ]; then
  info "Setting SUID permissions on chrome-sandbox..."
  chmod 4755 "$INSTALL_DIR/chrome-sandbox"
fi


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
mv "${BUILD_DIR}.deb" "$DEB_FILE"

# === FINAL CLEANUP ===
info "Final cleanup..."
# (trap handles the removal of $TMP_BUILD_DIR on exit)

echo "Done! Output: ${DEB_FILE}"
