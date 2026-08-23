#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Zig (stable releases)
# - Downloads pre-compiled Zig binary from ziglang.org
# - Packages it under /usr/lib/zig/VERSION/ using the alternatives system

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

BUILD_TMP=$(mktemp -d -t makezig.XXXXXX)
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

for cmd in curl wget tar jq dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

# Version selection:
# - If an argument is provided, use it as the version.
# - Otherwise, query ziglang.org API for the latest stable release.
INDEX_JSON="${BUILD_TMP}/zig-index.json"
info "Fetching ziglang.org release index..."
curl -fsS https://ziglang.org/download/index.json -o "${INDEX_JSON}" \
  || die "Failed to fetch ziglang.org download index."

if [ $# -ge 1 ]; then
  VERSION="$1"
  info "Using specified version: ${VERSION}"
else
  info "Querying latest stable version from ziglang.org..."
  VERSION=$(jq -r 'keys[]' "${INDEX_JSON}" | grep -v 'master' | sort -V | tail -n 1)
  info "Latest stable version detected: ${VERSION}"
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "Invalid Zig version '${VERSION}' (expected e.g. 0.16.0)"
fi

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  "amd64") ZIG_ARCH="x86_64" ;;
  "arm64") ZIG_ARCH="aarch64" ;;
  "armel") ZIG_ARCH="arm" ;;
  "riscv64") ZIG_ARCH="riscv64" ;;
  "ppc64el") ZIG_ARCH="powerpc64le" ;;
  "i386") ZIG_ARCH="x86" ;;
  "loong64") ZIG_ARCH="loongarch64" ;;
  "s390x") ZIG_ARCH="s390x" ;;
  *) die "Unsupported architecture: $ARCH" ;;
esac

MAJOR_MINOR=$(echo "$VERSION" | cut -d'.' -f1,2)
PKGNAME="zig-${MAJOR_MINOR}"

TARBALL="zig-${ZIG_ARCH}-linux-${VERSION}.tar.xz"
DOWNLOAD_URL="https://ziglang.org/download/${VERSION}/${TARBALL}"

DEB_NAME="${PKGNAME}_${VERSION}_${ARCH}.deb"
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

EXPECTED_SHA=$(jq -r --arg v "${VERSION}" --arg t "${ZIG_ARCH}-linux" '.[$v][$t].shasum // empty' "${INDEX_JSON}")
if [[ -z "$EXPECTED_SHA" ]]; then
  die "No published sha256 for Zig ${VERSION} (${ZIG_ARCH}-linux); refusing unverified download."
fi

info "Downloading Zig compiler: ${DOWNLOAD_URL}"
wget -q "$DOWNLOAD_URL" -O "${BUILD_TMP}/zig.tar.xz"

ACTUAL_SHA=$(sha256sum "${BUILD_TMP}/zig.tar.xz" | cut -d' ' -f1)
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  die "Checksum mismatch for Zig ${VERSION} tarball: expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
fi
info "Checksum verified: ${ACTUAL_SHA}"

info "Extracting compiler..."
tar -xf "${BUILD_TMP}/zig.tar.xz" -C "${BUILD_TMP}"

PKGDIR="${BUILD_TMP}/pkg"
mkdir -p "${PKGDIR}/usr/lib/zig/${VERSION}"

info "Staging files..."
cp "${BUILD_TMP}/zig-${ZIG_ARCH}-linux-${VERSION}/zig" "${PKGDIR}/usr/lib/zig/${VERSION}/"
cp -r "${BUILD_TMP}/zig-${ZIG_ARCH}-linux-${VERSION}/lib" "${PKGDIR}/usr/lib/zig/${VERSION}/"

# Document dir
DOC_DIR="${PKGDIR}/usr/share/doc/${PKGNAME}"
mkdir -p "${DOC_DIR}"
if [[ -f "${BUILD_TMP}/zig-${ZIG_ARCH}-linux-${VERSION}/LICENSE" ]]; then
  install -Dm644 "${BUILD_TMP}/zig-${ZIG_ARCH}-linux-${VERSION}/LICENSE" "${DOC_DIR}/copyright"
fi
if [[ -f "${BUILD_TMP}/zig-${ZIG_ARCH}-linux-${VERSION}/README.md" ]]; then
  install -Dm644 "${BUILD_TMP}/zig-${ZIG_ARCH}-linux-${VERSION}/README.md" "${DOC_DIR}/README.md"
fi

# Create DEBIAN metadata control
mkdir -p "${PKGDIR}/DEBIAN"

cat >"${PKGDIR}/DEBIAN/control" <<EOF
Package: ${PKGNAME}
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: ${ARCH}
Maintainer: Michael Garcia <thecrazygm@gmail.com>
Description: Zig is a general-purpose programming language and toolchain
Homepage: https://ziglang.org/
Provides: zig
EOF

# Install system postinst script for alternatives management
cat >"${PKGDIR}/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
ZIG_BIN="/usr/lib/zig/${VERSION}/zig"
if [ -f "\$ZIG_BIN" ]; then
    update-alternatives --install /usr/bin/zig zig "\$ZIG_BIN" 100
fi
exit 0
EOF
chmod 755 "${PKGDIR}/DEBIAN/postinst"

# Install system prerm script for alternatives management
cat >"${PKGDIR}/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
ZIG_BIN="/usr/lib/zig/${VERSION}/zig"
if [ -f "\$ZIG_BIN" ]; then
    update-alternatives --remove zig "\$ZIG_BIN" || true
fi
exit 0
EOF
chmod 755 "${PKGDIR}/DEBIAN/prerm"

# Normalize metadata timestamps
SOURCE_DATE_EPOCH=$(date +%s)
export SOURCE_DATE_EPOCH

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

dpkg-deb --build --root-owner-group "${PKGDIR}" "${DEB_FILE}"

info "Done! Output: ${DEB_FILE}"
