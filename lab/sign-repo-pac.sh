#!/usr/bin/env bash
#
# Stage S for the pacman format: turn the packages stage A produced into a
# signed pacman repository.
#
# Format-level, not consumer-level. pacman is the reader; what is produced here
# is a database plus its signature, which is what any pacman-compatible consumer
# checks.
#
#   env: SIGNING_KEY_B64, PKGS (stage A's out/*.pkg.tar.zst), OUT, LINE
#
# The keyring package that carries the trust root is NOT built here: pacman has
# no per-repository key scope and the root secret never enters CI, so bootstrapping
# trust is a trusted-machine step (pacman-key --add + --lsign-key).
set -euo pipefail

PKGS="${PKGS:?}"; OUT="${OUT:?}"; LINE="${LINE:-pac}"
KEY_B64="${SIGNING_KEY_B64:-}"
if [ -z "$KEY_B64" ]; then IFS= read -r KEY_B64 || true; fi
[ -n "$KEY_B64" ] || { echo "!! no signing key supplied"; exit 1; }

echo "=== S/pacman $LINE ==="
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "--- tooling (Arch's own) ---"
echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm --needed archlinux-keyring >/dev/null 2>&1 || true
pacman -S --noconfirm --needed gnupg pacman-contrib >/dev/null 2>&1 || true
echo "  repo-add: $(command -v repo-add)"

echo
echo "--- import this row's subkey ---"
printf '%s\n' "$KEY_B64" | base64 -d | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
mapfile -t SUBS < <(gpg --with-colons --list-secret-keys 2>/dev/null \
                    | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
if [ "${#SUBS[@]}" -ne 1 ]; then
  echo "  !! expected exactly 1 usable subkey here, found ${#SUBS[@]}"; exit 1
fi
SUB_FPR="${SUBS[0]}"
echo "  subkey = $SUB_FPR"

echo
echo "--- assert the root secret is not usable in CI ---"
ROOTFP=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
PROBE=$(mktemp)
if printf 'probe\n' | gpg --batch --local-user "${ROOTFP}!" --detach-sign -o "$PROBE" 2>/dev/null; then
  rm -f "$PROBE"; echo "  !! the root secret can sign here - contradicts the design"; exit 1
fi
rm -f "$PROBE"
echo "  OK: signing as the root key is refused here"

mkdir -p "$OUT"
cp -v "$PKGS"/*.pkg.tar.zst "$OUT"/ | sed 's/^/  /'

echo
echo "--- sign each package (per-package .sig) ---"
for f in "$OUT"/*.pkg.tar.zst; do
  gpg --batch --yes --local-user "${SUB_FPR}!" --detach-sign "$f"
  printf '  %-44s sig %s bytes\n' "$(basename "$f")" \
    "$(wc -c < "$f.sig" | tr -d ' ')"
done

echo
echo "--- build the database and sign it ---"
cd "$OUT"
rm -f lab.db* lab.files*
# -s signs the database, -k names the key to sign with.
repo-add -s -k "$SUB_FPR" lab.db.tar.gz ./*.pkg.tar.zst 2>&1 | sed 's/^/  /'

echo
echo "--- what a consumer fetches ---"
ls -l "$OUT" | sed 's/^/  /'
echo
echo "  database signature:"
if [ -f "$OUT/lab.db.tar.gz.sig" ]; then
  gpg --verify "$OUT/lab.db.tar.gz.sig" "$OUT/lab.db.tar.gz" 2>&1 | sed 's/^/    /'
else
  echo "    !! no lab.db.tar.gz.sig was produced"; exit 1
fi
