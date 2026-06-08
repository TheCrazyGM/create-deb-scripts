#!/usr/bin/env bash
set -euo pipefail
umask 0022

# Simple standalone Debian package builder for hide.me CLI (git)
# - Clones hide.client.linux, builds with Go, stages install, and assembles a .deb

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO]  $*"
}

OUTDIR=$(pwd)

TMPDIR=$(mktemp -d -t makehideme.XXXXXX)
cleanup() {
  if [[ -n "${TMPDIR:-}" && -d "${TMPDIR}" ]]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT INT TERM
info "Using temp dir: ${TMPDIR}"

for cmd in git go dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required tool: $cmd"
done

git clone --depth=1 https://github.com/eventure/hide.client.linux.git "${TMPDIR}/hide.client.linux"
cd "${TMPDIR}/hide.client.linux"

PKGVER=$(git describe --tags --always | sed -e 's/^v//' -e 's/-/./g')
COMMITS=$(git rev-list --count HEAD)
DATE=$(git log -1 --date=short --pretty=format:%cd | sed 's/-/./g' | sed 's/_/./g')
if [[ "$PKGVER" =~ ^(.*)\.([0-9]+)\.g([0-9a-f]+)$ ]]; then
  UPSTREAM="${BASH_REMATCH[1]}"
  HASH="${BASH_REMATCH[3]}"
elif [[ "$PKGVER" =~ ^([0-9a-f]+)$ ]]; then
  UPSTREAM=$(grep -oE 'writer\.Write\( \[\]byte\( "[0-9.]+" \) \)' control/methods.go | cut -d'"' -f2 || echo "0.0.0")
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

PKGNAME="hide.me"
PKGDESC="hide.me CLI VPN client for Linux"
MAINTAINER="Michael Garcia <thecrazygm@gmail.com>"
URL="https://github.com/eventure/hide.client.linux"
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

# Go build
info "Building hide.me CLI VPN client"
go build -o hide.me

PKGDIR="${TMPDIR}/pkg"
mkdir -p "${PKGDIR}/opt/hide.me"
mkdir -p "${PKGDIR}/usr/bin"
mkdir -p "${PKGDIR}/lib/systemd/system"

info "Staging install"
cp hide.me CA.pem hide.me@.service config "${PKGDIR}/opt/hide.me"
chmod +x "${PKGDIR}/opt/hide.me/hide.me"
touch "${PKGDIR}/opt/hide.me/config"

# Create symlink for the binary to /usr/bin/hide.me
ln -sf /opt/hide.me/hide.me "${PKGDIR}/usr/bin/hide.me"

# Install systemd service
cp hide.me@.service "${PKGDIR}/lib/systemd/system/hide.me@.service"

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
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${PKGDESC}
Homepage: ${URL}
Depends: libc6, ca-certificates
Provides: hide.me
Conflicts: hide.me
Replaces: hide.me
EOF

# postinst script to reload systemd daemon
cat <<'EOF' >"${PKGDIR}/DEBIAN/postinst"
#!/bin/bash
set -e
if command -v systemctl &>/dev/null; then
  systemctl daemon-reload || true
fi
EOF
chmod +x "${PKGDIR}/DEBIAN/postinst"

# postrm script to reload systemd daemon on removal
cat <<'EOF' >"${PKGDIR}/DEBIAN/postrm"
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v systemctl &>/dev/null; then
    systemctl daemon-reload || true
  fi
fi
EOF
chmod +x "${PKGDIR}/DEBIAN/postrm"

find "${PKGDIR}" -exec touch -h -d @"${SOURCE_DATE_EPOCH}" {} +
chmod -R a+rX "${PKGDIR}"
chmod 0755 "${PKGDIR}/DEBIAN" || true
chmod 0644 "${PKGDIR}/DEBIAN/control"

DEB_NAME="${PKGNAME}_${FULLVER}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKGDIR}" "${OUTDIR}/${DEB_NAME}"

info "Done! Output: ${OUTDIR}/${DEB_NAME}"
