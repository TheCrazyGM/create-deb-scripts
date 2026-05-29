#!/bin/bash
# This script fetches the latest Google Antigravity release and builds a Debian package.
set -euo pipefail

# Logging helpers
die() {
  echo "[ERROR] $*" >&2
  exit 1
}
info() { echo "[INFO]  $*"; }

# Create temporary build directory
TMP_BUILD_DIR=$(mktemp -d /tmp/antigravity-build.XXXXXX)

# Cleanup on exit
trap 'rm -rf "$TMP_BUILD_DIR" 2>/dev/null || true' EXIT

# === CONFIG ===
PACKAGE_NAME="antigravity"
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
info "Fetching releases page to find JavaScript bundle..."
html_content=$(curl -sL --compressed "$RELEASES_PAGE_URL" || curl -sL --compressed "https://antigravity.google/download")
MAIN_JS=$(echo "$html_content" | grep -oE 'main-[a-zA-Z0-9]+\.js' | head -n 1)

if [ -z "$MAIN_JS" ]; then
  die "Failed to locate main JavaScript bundle on the releases page."
fi

info "Fetching JavaScript bundle: $MAIN_JS..."
curl -sL --compressed -o "$TEMP_JS" "$BASE_URL/$MAIN_JS"

info "Parsing download URL and version from JavaScript bundle..."
DOWNLOAD_FIELDS=$(python3 - "$TEMP_JS" "$ARCH_SUFFIX" <<'PY'
import sys, re, pathlib
bundle_path = sys.argv[1]
platform = sys.argv[2]
bundle = pathlib.Path(bundle_path).read_text(encoding="utf-8", errors="ignore")

# Method 1: Section-based search (from website config structure)
start = bundle.find('id:"antigravity-2"')
end = bundle.find('},{name:"command",id:"antigravity-cli"', start)
if start != -1 and end != -1:
    section = bundle[start:end]
    match = re.search(r'href:"([^"]+/' + re.escape(platform) + r'/Antigravity\.tar\.gz)"', section)
    if match:
        url = match.group(1)
        version_match = re.search(r'/antigravity-hub/([^/]+)/', url)
        if version_match:
            print(f"{version_match.group(1)} {url}")
            sys.exit(0)

# Method 2: Global URL search fallback
match = re.search(r'href:"(https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[0-9a-zA-Z.-]+/' + re.escape(platform) + r'/Antigravity\.tar\.gz)"', bundle)
if match:
    url = match.group(1)
    version_match = re.search(r'/antigravity-hub/([^/]+)/', url)
    if version_match:
        print(f"{version_match.group(1)} {url}")
        sys.exit(0)

sys.exit(1)
PY
)

TARBALL_URL=""
VERSION=""

if [ -n "$DOWNLOAD_FIELDS" ]; then
  VERSION=$(echo "$DOWNLOAD_FIELDS" | cut -d' ' -f1)
  TARBALL_URL=$(echo "$DOWNLOAD_FIELDS" | cut -d' ' -f2)
  info "Found version $VERSION from JS bundle."
else
  # Try to extract API URL from JS bundle
  API_URL=$(echo "$js_content" | grep -oE 'https://antigravity-auto-updater-[0-9a-zA-Z.-]+\.run\.app/releases' | head -n 1 || true)
  if [ -n "$API_URL" ]; then
    info "Querying auto-updater API: $API_URL..."
    api_response=$(curl -sL "$API_URL" || true)
    if [ -n "$api_response" ]; then
      VERSION_VAL=$(echo "$api_response" | jq -r '.[0].version' 2>/dev/null || true)
      EXEC_ID=$(echo "$api_response" | jq -r '.[0].execution_id' 2>/dev/null || true)
      if [ -n "$VERSION_VAL" ] && [ "$VERSION_VAL" != "null" ] && [ -n "$EXEC_ID" ] && [ "$EXEC_ID" != "null" ]; then
        VERSION="${VERSION_VAL}-${EXEC_ID}"
        TARBALL_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${VERSION}/${ARCH_SUFFIX}/Antigravity.tar.gz"
        info "Found version $VERSION from API."
      fi
    fi
  fi
fi

if [ -z "$TARBALL_URL" ]; then
  info "Fallback: locating download URL directly in JavaScript bundle..."
  TARBALL_URL=$(echo "$js_content" | grep -oE "https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[0-9a-zA-Z.-]+/${ARCH_SUFFIX}/Antigravity\.tar\.gz" | head -n 1 || true)
  if [ -z "$TARBALL_URL" ]; then
    die "Tarball URL for $ARCH ($ARCH_SUFFIX) not found."
  fi
  VERSION=$(echo "$TARBALL_URL" | sed -n "s|.*/antigravity-hub/\([^/]*\)/${ARCH_SUFFIX}/.*|\1|p")
  if [ -z "$VERSION" ]; then
    die "Failed to extract version from URL: $TARBALL_URL"
  fi
fi

DEB_VERSION="$VERSION"

info "Latest version: $DEB_VERSION"

DEB_FILE="${OUTDIR}/${PACKAGE_NAME}_${DEB_VERSION}.deb"
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

TARBALL="$TMP_BUILD_DIR/antigravity.tar.gz"
BUILD_DIR="$TMP_BUILD_DIR/${PACKAGE_NAME}_${DEB_VERSION}"
INSTALL_DIR="$BUILD_DIR/opt/google/antigravity"
BIN_DIR="$BUILD_DIR/usr/local/bin"
DESKTOP_DIR="$BUILD_DIR/usr/share/applications"

info "Downloading $TARBALL_URL..."

# === DOWNLOAD THE TARBALL ===
curl -L -o "$TARBALL" "$TARBALL_URL"

# === PROCEED WITH DEB CREATION ===
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR"

# === EXTRACT THE TARBALL ===
info "Extracting tarball..."
tar -xf "$TARBALL" -C "$TMP_BUILD_DIR"

# Find extracted folder (e.g. Antigravity-x64 or Antigravity-arm)
EXTRACTED_DIR=$(find "$TMP_BUILD_DIR" -maxdepth 2 -type d -name "Antigravity-*" | head -n 1)
if [ -z "$EXTRACTED_DIR" ] && [ -d "$TMP_BUILD_DIR/Antigravity" ]; then
  EXTRACTED_DIR="$TMP_BUILD_DIR/Antigravity"
fi
if [ -z "$EXTRACTED_DIR" ]; then
  die "Could not find extracted Antigravity folder"
fi

info "Moving files from $EXTRACTED_DIR to $INSTALL_DIR..."
mv "$EXTRACTED_DIR"/* "$INSTALL_DIR/"
rm -rf "$EXTRACTED_DIR"

# === SET CHROME-SANDBOX PERMISSIONS ===
if [ -f "$INSTALL_DIR/chrome-sandbox" ]; then
  info "Setting SUID permissions on chrome-sandbox..."
  chmod 4755 "$INSTALL_DIR/chrome-sandbox"
fi


# === CREATE EXECUTABLE WRAPPER ===
info "Creating wrapper script..."
cat <<EOF >"$BIN_DIR/antigravity"
#!/bin/bash
exec /opt/google/antigravity/antigravity "\$@"
EOF
chmod +x "$BIN_DIR/antigravity"

# === INSTALL ICONS ===
info "Installing icons..."
ICON_TARGET_DIR="$BUILD_DIR/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$ICON_TARGET_DIR"
if curl -sL --compressed "https://antigravity.google/assets/image/antigravity-logo.svg" -o "$ICON_TARGET_DIR/antigravity.svg"; then
  info "Icon downloaded successfully."
else
  echo "Warning: Failed to download icon from website." >&2
fi

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
mv "${BUILD_DIR}.deb" "$OUTDIR/"

# === FINAL CLEANUP ===
info "Final cleanup..."
# (trap handles the removal of $TMP_BUILD_DIR on exit)

echo "Done! Output: ${OUTDIR}/${PACKAGE_NAME}_${DEB_VERSION}.deb"
