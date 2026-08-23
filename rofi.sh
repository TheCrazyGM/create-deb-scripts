#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Rofi (git)
# - Clones rofi, builds with Meson/Ninja, stages install, and assembles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

TMPDIR=$(mktemp -d -t makerofi.XXXXXX)
cleanup() {
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT
# Signal traps exit so the EXIT trap (and cleanup) runs exactly once.
trap 'exit 130' INT
trap 'exit 143' TERM
info "Using temp dir: ${TMPDIR}"

for cmd in git meson ninja dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

git clone --depth=1 https://github.com/davatorium/rofi.git "${TMPDIR}/rofi"
cd "${TMPDIR}/rofi"
git submodule update --init --recursive

PKGVER=$(git describe --tags --always | sed -e 's/^v//' -e 's/-/./g')
COMMITS=$(git rev-list --count HEAD)
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's/-/./g' | sed 's/_/./g')
# Depth-1 clones fetch no tags, so git describe always falls back to a
# short commit hash; the upstream version comes from project metadata.
if [[ "$PKGVER" =~ ^([0-9a-f]+)$ ]]; then
  UPSTREAM=$(grep -m 1 -oE "\bversion:\s*'[^']+'" meson.build | cut -d"'" -f2)
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

PKGNAME="rofi-git"
PKGDESC="Unified window switcher, run dialog, and dmenu replacement"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://github.com/davatorium/rofi"
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

# Runtime deps aligned with INSTALL.md guidance and linked libraries from build output
DEPENDS="libc6, libcairo2, libglib2.0-0 (>= 2.72), libgdk-pixbuf-2.0-0, libpango-1.0-0 (>= 1.50), libpangocairo-1.0-0 (>= 1.50), libstartup-notification0, libwayland-client0, libwayland-cursor0, libxcb1 (>= 1.14), libxcb-cursor0, libxcb-ewmh2, libxcb-icccm4, libxcb-keysyms1, libxcb-randr0, libxcb-render0, libxcb-util1, libxcb-xinerama0, libxcb-xkb1, libxkbcommon0 (>= 0.4.1), libxkbcommon-x11-0"

BUILD_DIR=build
rm -rf "${BUILD_DIR}"

info "Configuring build with Meson"
meson setup "${BUILD_DIR}" \
  --prefix=/usr \
  --buildtype=release \
  -Dwayland=enabled \
  -Dxcb=enabled

info "Building Rofi"
ninja -C "${BUILD_DIR}" -v

PKGDIR="${TMPDIR}/pkg"
mkdir -p "${PKGDIR}"

info "Staging install"
DESTDIR="${PKGDIR}" ninja -C "${BUILD_DIR}" install

DOC_DIR="${PKGDIR}/usr/share/doc/rofi"
mkdir -p "${DOC_DIR}"
if [[ -f LICENSE ]]; then
  install -Dm644 LICENSE "${DOC_DIR}/LICENSE"
fi
if [[ -f README.md ]]; then
  install -Dm644 README.md "${DOC_DIR}/README.md"
fi

mkdir -p "${PKGDIR}/DEBIAN"

cat >"${PKGDIR}/DEBIAN/control" <<EOF
Package: ${PKGNAME}
Version: ${FULLVER}
Section: x11
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${PKGDESC}
Homepage: ${URL}
Depends: ${DEPENDS}
Provides: rofi
Conflicts: rofi
Replaces: rofi
EOF

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUTDIR}/${DEB_NAME}"

info "Done! Output: ${OUTDIR}/${DEB_NAME}"
