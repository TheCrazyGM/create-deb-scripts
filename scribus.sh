#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Scribus (development version)
# - Parses SourceForge RSS feed to find the latest development AppImage
# - Downloads, extracts, stages the files, and compiles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

BUILD_TMP=$(mktemp -d -t makescribus.XXXXXX)
cleanup() {
  if [[ -n "${BUILD_TMP:-}" && -d "${BUILD_TMP}" ]]; then
    rm -rf "${BUILD_TMP}"
  fi
}
trap cleanup EXIT
# Signal traps exit so the EXIT trap (and cleanup) runs exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
info "Using temp dir: ${BUILD_TMP}"

for cmd in curl wget grep sed dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" != "amd64" ]]; then
  die "Upstream publishes Scribus development AppImages for x86_64 only; unsupported architecture: $ARCH"
fi

info "Fetching latest release details from SourceForge RSS feed..."
RSS_URL="https://sourceforge.net/projects/scribus/rss?path=/scribus-devel"
APPIMAGE_URL=$(curl -s "$RSS_URL" | \
  grep -oP 'https://sourceforge.net/projects/scribus/files/scribus-devel/[^/]+/scribus-[0-9.]+-linux-x86_64\.AppImage/download' | \
  head -n 1)

if [[ -z "$APPIMAGE_URL" ]]; then
  die "Could not find Scribus AppImage download URL in the SourceForge RSS feed."
fi

VERSION=$(echo "$APPIMAGE_URL" | grep -oP 'scribus-devel/\K[^/]+')
info "Latest development version detected: ${VERSION}"

DEB_NAME="scribus-devel_${VERSION}_$(dpkg --print-architecture).deb"
DEB_FILE="${OUTDIR}/${DEB_NAME}"

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

info "Downloading AppImage: ${APPIMAGE_URL}"
wget -O "${BUILD_TMP}/scribus.AppImage" "$APPIMAGE_URL"

info "Extracting AppImage..."
cd "${BUILD_TMP}"
chmod +x scribus.AppImage
./scribus.AppImage --appimage-extract

PKGDIR="${BUILD_TMP}/pkg"
mkdir -p "${PKGDIR}/opt/scribus"
mkdir -p "${PKGDIR}/usr/bin"
mkdir -p "${PKGDIR}/usr/share/applications"
mkdir -p "${PKGDIR}/usr/share/pixmaps"

info "Staging files..."
cp -r "${BUILD_TMP}/squashfs-root/"* "${PKGDIR}/opt/scribus/"

# Create symlinks
ln -sf /opt/scribus/AppRun "${PKGDIR}/usr/bin/scribus"
ln -sf /opt/scribus/AppRun "${PKGDIR}/usr/bin/scribus-devel"

# Install icons
if [[ -f "${BUILD_TMP}/squashfs-root/scribus.png" ]]; then
  cp "${BUILD_TMP}/squashfs-root/scribus.png" "${PKGDIR}/usr/share/pixmaps/scribus-devel.png"
  cp "${BUILD_TMP}/squashfs-root/scribus.png" "${PKGDIR}/usr/share/pixmaps/scribus.png"
fi

# Install desktop files
if [[ -f "${BUILD_TMP}/squashfs-root/scribus.desktop" ]]; then
  # 1. Developer Launcher
  cp "${BUILD_TMP}/squashfs-root/scribus.desktop" "${PKGDIR}/usr/share/applications/scribus-devel.desktop"
  sed -i 's|^Exec=.*|Exec=/usr/bin/scribus-devel %f|' "${PKGDIR}/usr/share/applications/scribus-devel.desktop"
  sed -i 's|^Name=.*|Name=Scribus (Development)|' "${PKGDIR}/usr/share/applications/scribus-devel.desktop"
  sed -i 's|^Icon=.*|Icon=scribus-devel|' "${PKGDIR}/usr/share/applications/scribus-devel.desktop"

  # 2. Main Launcher (conflicts/replaces package standard)
  cp "${BUILD_TMP}/squashfs-root/scribus.desktop" "${PKGDIR}/usr/share/applications/scribus.desktop"
  sed -i 's|^Exec=.*|Exec=/usr/bin/scribus %f|' "${PKGDIR}/usr/share/applications/scribus.desktop"
  sed -i 's|^Name=.*|Name=Scribus (Development)|' "${PKGDIR}/usr/share/applications/scribus.desktop"
  sed -i 's|^Icon=.*|Icon=scribus|' "${PKGDIR}/usr/share/applications/scribus.desktop"
fi

# Document dir
DOC_DIR="${PKGDIR}/usr/share/doc/scribus-devel"
mkdir -p "${DOC_DIR}"
LICENSE_FILE=""
for candidate in LICENSE COPYING LICENSE.txt COPYING.txt; do
  if [[ -f "${BUILD_TMP}/squashfs-root/${candidate}" ]]; then
    LICENSE_FILE="${BUILD_TMP}/squashfs-root/${candidate}"
    break
  fi
done
if [[ -n "$LICENSE_FILE" ]]; then
  cp "${LICENSE_FILE}" "${DOC_DIR}/copyright"
else
  cat >"${DOC_DIR}/copyright" <<'EOT'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Source: https://sourceforge.net/projects/scribus/files/scribus-devel/
License: GPL-2.0+
 Scribus is licensed under the GNU General Public License version 2 or later.
EOT
fi

# Create DEBIAN control metadata
mkdir -p "${PKGDIR}/DEBIAN"
PKGNAME="scribus-devel"
PKGDESC="Scribus page layout and publication (development version)"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://www.scribus.net/"

cat >"${PKGDIR}/DEBIAN/control" <<EOF
Package: ${PKGNAME}
Version: ${VERSION}
Section: graphics
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${PKGDESC}
Homepage: ${URL}
Depends: libc6, zlib1g
Provides: scribus
Conflicts: scribus
Replaces: scribus
EOF

# Install caches postinst script
cat <<'EOF' >"${PKGDIR}/DEBIAN/postinst"
#!/bin/bash
set -e
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor || true
fi
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database -q /usr/share/applications || true
fi
EOF
chmod +x "${PKGDIR}/DEBIAN/postinst"

# Normalize metadata timestamps
SOURCE_DATE_EPOCH=$(date +%s)
export SOURCE_DATE_EPOCH

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

dpkg-deb --build --root-owner-group "${PKGDIR}" "${DEB_FILE}"

info "Done! Output: ${DEB_FILE}"
