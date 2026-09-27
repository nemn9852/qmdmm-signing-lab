#!/usr/bin/env bash
#
# Sign a throwaway pacman repository inside a real archlinux:base container,
# using the per-distro subkey whose secret arrives on stdin as base64.
#
# Contract:
#   stdin : one line, base64 of `gpg --armor --export-secret-subkeys "<fpr>!"`
#   env   : SUB_FPR = fingerprint of this line's signing subkey
#           OUT     = output dir inside the container (default /w/out/arch)
set -euo pipefail

# Read the secret off stdin FIRST: pacman below consumes stdin.
IFS= read -r KEY_B64 || true

SUB_FPR="${SUB_FPR:?}"
OUT="${OUT:-/w/out/arch}"
DAILY="$OUT/daily"

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg:    $(gpg --version | head -1)"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "=== dependencies ==="
# archlinux:base ships an entirely commented-out mirrorlist, so pacman -Sy
# fails with "no servers configured for repository" until one is added.
if ! grep -qE '^[[:space:]]*Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
  echo "  (base image had no mirror; wrote geo.mirror.pkgbuild.com)"
fi
pacman -Sy --noconfirm --needed gnupg zstd > /tmp/pacman-install.log 2>&1 </dev/null \
  || { tail -20 /tmp/pacman-install.log; exit 1; }

echo
echo "=== import subkey from stdin ==="
printf '%s\n' "$KEY_B64" | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'

echo
echo "=== assert: no usable primary secret in this container ==="
if gpg --list-secret-keys --with-colons | awk -F: '$1=="sec" && $2!="e"' | grep -q .; then
  echo "  !! a usable primary secret is present"; exit 1
fi
echo "  OK"

echo
echo "=== build a throwaway package (.pkg.tar.zst) ==="
P=/tmp/pkgroot; rm -rf "$P"; mkdir -p "$P"
cat > "$P/.PKGINFO" <<'EOF'
pkgname = qmdmm-lab
pkgver = 1.0-1
pkgdesc = QMdmm signing lab test package
url = https://example.invalid
builddate = 1758960000
packager = QMdmm signing lab
size = 4
arch = any
EOF
mkdir -p "$DAILY"
PKG="$DAILY/qmdmm-lab-1.0-1-any.pkg.tar.zst"
( cd "$P" && tar -cf - .PKGINFO ) | zstd -q -f -o "$PKG"

echo
echo "=== sign the package itself, then build + sign the db ==="
gpg --batch --yes --local-user "${SUB_FPR}!" --detach-sign "$PKG"
ls -l "$PKG".sig | sed 's/^/  /'

cd "$DAILY"
repo-add -s -k "$SUB_FPR" lab.db.tar.gz qmdmm-lab-1.0-1-any.pkg.tar.zst 2>&1 | sed 's/^/  /'

echo "  --- signature files ---"
ls -l ./*.sig 2>/dev/null | sed 's/^/    /' || echo "    (no .sig files at all - worth noting)"

echo "  --- who signed the db ---"
if [ -f lab.db.tar.gz.sig ]; then
  gpg --verify lab.db.tar.gz.sig lab.db.tar.gz 2>&1 | sed 's/^/    /'
fi

echo
echo "=== replace repo-add's symlinks with real files ==="
# repo-add creates lab.db -> lab.db.tar.gz symlinks. Artifact upload / Pages
# do not preserve symlinks, so materialise them (and the .db.sig pacman asks
# for, which repo-add names .db.tar.gz.sig).
for base in lab.db lab.files; do
  if [ -L "$base" ]; then
    rm -f "$base" "$base.sig"
    cp "${base}.tar.gz" "$base"
    cp "${base}.tar.gz.sig" "$base.sig" 2>/dev/null || true
    echo "  $base -> regular file (and ${base}.tar.gz.sig -> ${base}.sig)"
  fi
done
ls -l lab.db* lab.files* 2>/dev/null | sed 's/^/    /'

echo
echo "=== output ==="
find "$OUT" -type f | sort | sed 's/^/  /'
