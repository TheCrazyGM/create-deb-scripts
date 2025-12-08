#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Alacritty (git)
# - Clones alacritty, builds with Cargo, installs terminfo/man/completions, and assembles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

TMPDIR=$(mktemp -d -t makealacritty.XXXXXX)
cleanup() {
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT INT TERM
info "Using temp dir: ${TMPDIR}"

# Check for required tools
# Note: scdoc is optional but recommended for man pages.
#       gzip is needed for compressing man pages.
for cmd in git cargo rustc dpkg-deb tic gzip; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

# Optional tools
HAS_SCDOC=false
if command -v scdoc >/dev/null 2>&1; then
  HAS_SCDOC=true
else
  info "scdoc not found, man pages will NOT be generated."
fi

git clone --depth=1 https://github.com/alacritty/alacritty.git "${TMPDIR}/alacritty"
cd "${TMPDIR}/alacritty"
git submodule update --init --recursive

# Versioning strategy
PKGVER=$(git describe --tags --always | sed -e 's/^v//' -e 's/-/./g')
COMMITS=$(git rev-list --count HEAD)
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's/-/./g' | sed 's/_/./g')
FULLVER="${COMMITS}.${PKGVER}.${DATE}"
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export SOURCE_DATE_EPOCH

PKGNAME="alacritty-git"
PKGDESC="A cross-platform, GPU-accelerated terminal emulator"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://github.com/alacritty/alacritty"
ARCH=$(dpkg --print-architecture)

# Dependencies based on INSTALL.md and typical usage
# Build deps: cmake, pkg-config, libfreetype6-dev, libfontconfig1-dev, libxcb-xfixes0-dev, libxkbcommon-dev
# Runtime deps:
DEPENDS="libc6, libfontconfig1, libfreetype6, libxcb1, libxcb-render0, libxcb-shape0, libxcb-xfixes0, libxkbcommon0, libxkbcommon-x11-0"

info "Building Alacritty (release)"
cargo build --release --locked

PKGDIR="${TMPDIR}/pkg"
mkdir -p "${PKGDIR}"

# --- Installation ---

# 1. Binary
info "Installing binary"
install -Dm755 "target/release/alacritty" "${PKGDIR}/usr/bin/alacritty"

# 2. Terminfo
# Skipped to avoid conflict with ncurses-term which likely already has it.
# info "Installing terminfo"
# mkdir -p "${PKGDIR}/usr/share/terminfo"
# tic -xe alacritty,alacritty-direct -o "${PKGDIR}/usr/share/terminfo" extra/alacritty.info

# 3. Desktop Entry & Icon
info "Installing desktop entry and icon"
install -Dm644 "extra/linux/Alacritty.desktop" "${PKGDIR}/usr/share/applications/Alacritty.desktop"
install -Dm644 "extra/logo/alacritty-term.svg" "${PKGDIR}/usr/share/pixmaps/Alacritty.svg"

# 4. Man Pages (requires scdoc)
if [ "$HAS_SCDOC" = true ]; then
    info "Generating and installing man pages"
    mkdir -p "${PKGDIR}/usr/share/man/man1"
    mkdir -p "${PKGDIR}/usr/share/man/man5"
    
    scdoc < extra/man/alacritty.1.scd | gzip -c > "${PKGDIR}/usr/share/man/man1/alacritty.1.gz"
    scdoc < extra/man/alacritty-msg.1.scd | gzip -c > "${PKGDIR}/usr/share/man/man1/alacritty-msg.1.gz"
    scdoc < extra/man/alacritty.5.scd | gzip -c > "${PKGDIR}/usr/share/man/man5/alacritty.5.gz"
    scdoc < extra/man/alacritty-bindings.5.scd | gzip -c > "${PKGDIR}/usr/share/man/man5/alacritty-bindings.5.gz"
fi

# 5. Shell Completions
info "Installing shell completions"

# Bash
mkdir -p "${PKGDIR}/usr/share/bash-completion/completions"
cp "extra/completions/alacritty.bash" "${PKGDIR}/usr/share/bash-completion/completions/alacritty"

# Zsh
mkdir -p "${PKGDIR}/usr/share/zsh/vendor-completions"
cp "extra/completions/_alacritty" "${PKGDIR}/usr/share/zsh/vendor-completions/_alacritty"

# Fish
mkdir -p "${PKGDIR}/usr/share/fish/vendor_completions.d"
cp "extra/completions/alacritty.fish" "${PKGDIR}/usr/share/fish/vendor_completions.d/alacritty.fish"

# 6. Docs
DOC_DIR="${PKGDIR}/usr/share/doc/alacritty"
mkdir -p "${DOC_DIR}"
if [[ -f LICENSE-APACHE ]]; then
  install -Dm644 LICENSE-APACHE "${DOC_DIR}/LICENSE-APACHE"
fi
if [[ -f README.md ]]; then
  install -Dm644 README.md "${DOC_DIR}/README.md"
fi


# --- Packaging ---

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
Provides: alacritty
Conflicts: alacritty
Replaces: alacritty
EOF

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUTDIR}/${DEB_NAME}"

info "Done! Output: ${OUTDIR}/${DEB_NAME}"
