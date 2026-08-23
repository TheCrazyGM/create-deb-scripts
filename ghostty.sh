#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for Ghostty (git)
# - Clones ghostty, installs Zig 0.16.0 if needed, builds, stages, and compiles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

BUILD_TMP=$(mktemp -d -t makeghostty.XXXXXX)
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

for cmd in git dpkg-deb pkg-config wget tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

ARCH=$(dpkg --print-architecture)

# Check build dependencies
MISSING_DEPS=()
declare -A DEPS_MAP=(
  ["gtk4"]="libgtk-4-dev"
  ["libadwaita-1"]="libadwaita-1-dev"
  ["fontconfig"]="libfontconfig-dev"
  ["libpng"]="libpng-dev"
  ["oniguruma"]="libonig-dev"
  ["gtk4-layer-shell-0"]="libgtk4-layer-shell-dev"
)

for pkg in "${!DEPS_MAP[@]}"; do
  if ! pkg-config --exists "$pkg"; then
    MISSING_DEPS+=("${DEPS_MAP[$pkg]}")
  fi
done

if ! command -v blueprint-compiler >/dev/null 2>&1; then
  MISSING_DEPS+=("blueprint-compiler")
fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
  echo "[ERROR] Missing build-time Debian packages: ${MISSING_DEPS[*]}" >&2
  echo "Please install them by running:" >&2
  echo "  sudo apt install ${MISSING_DEPS[*]} libbz2-dev libxml2-utils" >&2
  exit 1
fi

# Detect or download correct Zig version
ZIG_CMD=""
if command -v zig >/dev/null 2>&1; then
  ZIG_VER=$(zig version 2>/dev/null || echo "0.0.0")
  if [[ "$ZIG_VER" == 0.16.* ]]; then
    ZIG_CMD="zig"
  fi
fi

if [[ -z "$ZIG_CMD" ]]; then
  for path in /usr/lib/zig/0.16.*/zig /usr/local/bin/zig /usr/bin/zig; do
    if [[ -x "$path" ]]; then
      VER=$("$path" version 2>/dev/null || echo "0.0.0")
      if [[ "$VER" == 0.16.* ]]; then
        info "Found local Zig 0.16.x at: $path"
        ZIG_CMD="$path"
        break
      fi
    fi
  done
fi

if [[ -z "$ZIG_CMD" ]]; then
  case "$ARCH" in
    amd64) ZIG_ARCH="x86_64" ;;
    arm64) ZIG_ARCH="aarch64" ;;
    *) die "No prebuilt Zig 0.16.0 toolchain available for architecture: $ARCH" ;;
  esac
  info "System zig is not 0.16.x and no local 0.16.x binary was found."
  info "Downloading Zig 0.16.0 compiler for ${ZIG_ARCH}..."
  wget -q "https://ziglang.org/download/0.16.0/zig-${ZIG_ARCH}-linux-0.16.0.tar.xz" -O "${BUILD_TMP}/zig.tar.xz"
  tar -xf "${BUILD_TMP}/zig.tar.xz" -C "${BUILD_TMP}"
  ZIG_CMD="${BUILD_TMP}/zig-${ZIG_ARCH}-linux-0.16.0/zig"
fi

git clone --depth=1 https://github.com/ghostty-org/ghostty.git "${BUILD_TMP}/ghostty"
cd "${BUILD_TMP}/ghostty"

PKGVER=$(git describe --tags --always | sed -e 's/^v//' -e 's/-/./g')
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's/-/./g' | sed 's/_/./g')
ZON_VER=$(grep -m 1 -oP '\.version\s*=\s*"\K[^"]+' build.zig.zon || echo "1.0.0")

# A shallow clone with no tags makes `git describe --always` return the
# abbreviated commit hash. Hashes can start with a digit, so checking only
# the first character incorrectly sends values such as `88b4cd0` to Zig as a
# version string. Require a semantic-version-like numeric prefix instead.
if [[ "$PKGVER" =~ ^[0-9]+\.[0-9]+ ]]; then
  if [[ "$PKGVER" =~ ^(.*)\.([0-9]+)\.g([0-9a-f]+)$ ]]; then
    UPSTREAM="${BASH_REMATCH[1]}"
    HASH="${BASH_REMATCH[3]}"
  else
    UPSTREAM="$PKGVER"
    HASH=""
  fi
else
  UPSTREAM="$ZON_VER"
  HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "")
fi

ZIG_VERSION="${UPSTREAM}"
if [[ -n "$HASH" ]]; then
  ZIG_VERSION="${ZIG_VERSION}+git.${DATE}.${HASH}"
fi

UPSTREAM_DEB="${UPSTREAM//-/\~}"

if [[ -n "$HASH" ]]; then
  FULLVER="${UPSTREAM_DEB}+git${DATE}.${HASH}"
else
  FULLVER="${UPSTREAM_DEB}+git${DATE}"
fi
SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct)
export SOURCE_DATE_EPOCH

PKGNAME="ghostty-git"
PKGDESC="Fast, feature-rich, and native terminal emulator"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://ghostty.org/"

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

# Apply the bzip2 to bz2 fix for Debian packaging
if [[ -f src/build/SharedDeps.zig ]]; then
  sed -i 's/linkSystemLibrary2("bzip2", dynamic_link_opts)/linkSystemLibrary2("bz2", dynamic_link_opts)/' src/build/SharedDeps.zig
fi

PKGDIR="${BUILD_TMP}/pkg"
mkdir -p "${PKGDIR}"

info "Building Ghostty with Zig"
DESTDIR="${PKGDIR}" "$ZIG_CMD" build \
  --summary all \
  --prefix /usr \
  --build-id \
  -Doptimize=ReleaseFast \
  -Dcpu=baseline \
  -Dpie=true \
  -Demit-docs \
  -Dstrip=false \
  -fsys=fontconfig \
  -Dversion-string="${ZIG_VERSION}"

info "Cleaning up static libraries and files"
find "${PKGDIR}" -name '*.a' -delete || true

# Remove conflicting standard terminfo entries (already in ncurses-term)
if [[ -d "${PKGDIR}/usr/share/terminfo/g" ]]; then
  rm -rf "${PKGDIR}/usr/share/terminfo/g"
fi

# Fix prefix path references in systemd/desktop launcher/dbus services
for file in "${PKGDIR}/usr/share/systemd/user/app-com.mitchellh.ghostty.service" \
  "${PKGDIR}/usr/share/applications/com.mitchellh.ghostty.desktop" \
  "${PKGDIR}/usr/share/dbus-1/services/com.mitchellh.ghostty.service"; do
  if [[ -f "$file" ]]; then
    sed -i 's|\./zig-out||g' "$file"
  fi
done

# Standardize zsh completions path for Debian
if [[ -d "${PKGDIR}/usr/share/zsh/site-functions" ]]; then
  mkdir -p "${PKGDIR}/usr/share/zsh/vendor-completions"
  mv "${PKGDIR}/usr/share/zsh/site-functions/"* "${PKGDIR}/usr/share/zsh/vendor-completions/"
  rm -rf "${PKGDIR}/usr/share/zsh/site-functions"
fi

# Create document directory
DOC_DIR="${PKGDIR}/usr/share/doc/${PKGNAME}"
mkdir -p "${DOC_DIR}"
if [[ -f LICENSE ]]; then
  install -Dm644 LICENSE "${DOC_DIR}/copyright"
fi
if [[ -f README.md ]]; then
  install -Dm644 README.md "${DOC_DIR}/README.md"
fi

# Generate Debian metadata control
mkdir -p "${PKGDIR}/DEBIAN"
cat >"${PKGDIR}/DEBIAN/control" <<EOF
Package: ${PKGNAME}
Version: ${FULLVER}
Section: utils
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${PKGDESC}
Homepage: ${URL}
Depends: libadwaita-1-0, libc6, libfontconfig1, libfreetype6, libglib2.0-0t64 | libglib2.0-0, libgtk-4-1, libgtk4-layer-shell0, libharfbuzz0b, libonig5, libx11-6
Provides: ghostty, x-terminal-emulator
Conflicts: ghostty
Replaces: ghostty
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

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUTDIR}/${DEB_NAME}"

info "Done! Output: ${OUTDIR}/${DEB_NAME}"
