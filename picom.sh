#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Picom (git)
# - Clones picom, builds with Meson/Ninja, stages install, and assembles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

TMPDIR=$(mktemp -d -t makepicom.XXXXXX)
cleanup() {
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT INT TERM
info "Using temp dir: ${TMPDIR}"

for cmd in git meson ninja dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

git clone --depth=1 https://github.com/yshui/picom.git "${TMPDIR}/picom"
cd "${TMPDIR}/picom"
git submodule update --init --recursive

PKGVER=$(git describe --tags --always | sed -e 's/^v//' -e 's/-/./g')
COMMITS=$(git rev-list --count HEAD)
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's/-/./g' | sed 's/_/./g')
FULLVER="${COMMITS}.${PKGVER}.${DATE}"
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export SOURCE_DATE_EPOCH

PKGNAME="picom-git"
PKGDESC="A lightweight compositor for X11"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://github.com/yshui/picom"
ARCH=$(dpkg --print-architecture)

# Runtime deps approximation for a standard Picom build
# Adjust as needed if enabling/disabling specific features
DEPENDS="libc6, libconfig11, libdbus-1-3, libegl1, libepoxy0, libev4, libgl1, libpcre2-8-0, libpixman-1-0, libx11-6, libx11-xcb1, libxcb-composite0, libxcb-damage0, libxcb-glx0, libxcb-image0, libxcb-present0, libxcb-randr0, libxcb-render0, libxcb-shape0, libxcb-sync1, libxcb-xfixes0, libxcb-xinerama0, libxcb1, libxext6"

BUILD_DIR=build
rm -rf "${BUILD_DIR}"

info "Configuring build with Meson"
# Standard release build.
# Explicitly enabling/disabling features can be done here if needed, e.g. -Dopengl=true
meson setup "${BUILD_DIR}" \
  --prefix=/usr \
  --buildtype=release \
  -Dwith_docs=true

info "Building Picom"
ninja -C "${BUILD_DIR}" -v

PKGDIR="${TMPDIR}/pkg"
mkdir -p "${PKGDIR}"

info "Staging install"
DESTDIR="${PKGDIR}" ninja -C "${BUILD_DIR}" install

DOC_DIR="${PKGDIR}/usr/share/doc/picom"
mkdir -p "${DOC_DIR}"
if [[ -f LICENSE ]]; then
  install -Dm644 LICENSE "${DOC_DIR}/LICENSE"
fi
if [[ -f README.md ]]; then
  install -Dm644 README.md "${DOC_DIR}/README.md"
fi
# picom might install a config file to /etc/xdg usually, ensuring it's handled
# or if we want to provide a default one, we could do it here.
# For now, we stick to upstream install defaults.

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
Provides: picom, compton
Conflicts: picom, compton
Replaces: picom, compton
EOF

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUTDIR}/${DEB_NAME}"

info "Done! Output: ${OUTDIR}/${DEB_NAME}"
