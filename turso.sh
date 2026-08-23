#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Turso Database CLI (git)
# - Clones turso, builds with Cargo, stages install, and assembles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

BUILD_TMP=$(mktemp -d -t maketurso.XXXXXX)
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

for cmd in git cargo rustc dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

git clone --depth=1 https://github.com/tursodatabase/turso.git "${BUILD_TMP}/turso"
cd "${BUILD_TMP}/turso"

PKGVER=$(git describe --tags --always | sed -e 's/^v//' -e 's/-/./g')
COMMITS=$(git rev-list --count HEAD)
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's/-/./g' | sed 's/_/./g')
# Depth-1 clones fetch no tags, so git describe always falls back to a
# short commit hash; the upstream version comes from project metadata.
if [[ "$PKGVER" =~ ^([0-9a-f]+)$ ]]; then
  UPSTREAM=$(grep -m 1 -E '^version = ' Cargo.toml | cut -d'"' -f2 || echo "0.0.0")
  HASH="${BASH_REMATCH[1]}"
else
  UPSTREAM="$PKGVER"
  HASH=""
fi

UPSTREAM="${UPSTREAM//-/\~}"

if [[ -n "$HASH" ]]; then
  FULLVER="${UPSTREAM}+git${DATE}.${HASH}"
else
  FULLVER="${UPSTREAM}+git${DATE}"
fi
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export SOURCE_DATE_EPOCH

PKGNAME="tursodb-git"
PKGDESC="The Turso interactive SQL shell"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://github.com/tursodatabase/turso"
ARCH=$(dpkg --print-architecture)

DEB_FILE="${OUTDIR}/${PKGNAME}_${FULLVER}_${ARCH}.deb"
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

# Build Turso CLI
info "Building Turso CLI (release)"
cargo build --release -p turso_cli --bin tursodb

PKGDIR="${BUILD_TMP}/pkg"
mkdir -p "${PKGDIR}/usr/bin"

info "Staging install"
install -Dm755 "target/release/tursodb" "${PKGDIR}/usr/bin/tursodb"

# Install documentation
DOC_DIR="${PKGDIR}/usr/share/doc/${PKGNAME}"
mkdir -p "${DOC_DIR}"
if [[ -f LICENSE.md ]]; then
  install -Dm644 LICENSE.md "${DOC_DIR}/copyright"
elif [[ -f LICENSE ]]; then
  install -Dm644 LICENSE "${DOC_DIR}/copyright"
fi
if [[ -f README.md ]]; then
  install -Dm644 README.md "${DOC_DIR}/README.md"
fi

mkdir -p "${PKGDIR}/DEBIAN"

cat >"${PKGDIR}/DEBIAN/control" <<EOF
Package: ${PKGNAME}
Version: ${FULLVER}
Section: database
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${PKGDESC}
Homepage: ${URL}
Depends: libc6
Provides: tursodb
Conflicts: tursodb
Replaces: tursodb
EOF

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUTDIR}/${DEB_NAME}"

info "Done! Output: ${OUTDIR}/${DEB_NAME}"
