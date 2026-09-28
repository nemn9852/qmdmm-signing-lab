#!/usr/bin/env bash
#
# Stage S for the rpm format: turn the packages stage A produced into a signed
# rpm repository - signed repodata plus signed packages.
#
# Format-level, not consumer-level. dnf reads what this produces, but so would
# zypper: nothing below is dnf-specific, and the artifact is reusable per
# consumer without re-signing.
#
#   env: SIGNING_KEY_B64, PKGS (stage A's out/*.rpm), OUT, LINE, ARCH (default x86_64)
#
# The keyring/`*-release` package that carries the trust root is NOT built here:
# the root secret never enters CI. This signs with this row's subkey only.
set -euo pipefail

PKGS="${PKGS:?}"; OUT="${OUT:?}"; LINE="${LINE:-rpm}"; ARCH="${ARCH:-x86_64}"
KEY_B64="${SIGNING_KEY_B64:-}"
if [ -z "$KEY_B64" ]; then IFS= read -r KEY_B64 || true; fi
[ -n "$KEY_B64" ] || { echo "!! no signing key supplied"; exit 1; }

echo "=== S/rpm $LINE ==="
# Not `. /etc/os-release`: that defines ARCH too, which is an input here.
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  rpm: $(rpm --version)   dnf: $(dnf --version | head -1)   backend: $(rpm --eval '%_openpgp_sign' 2>/dev/null)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 rpm-sign createrepo_c </dev/null >/dev/null 2>&1 || true
echo "  rpmsign:     $(command -v rpmsign)"
echo "  createrepo_c: $(command -v createrepo_c)"

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
cp -v "$PKGS"/*.rpm "$OUT"/ | sed 's/^/  /'

echo
echo "--- sign each package with this row's subkey (package level) ---"
for f in "$OUT"/*.rpm; do
  # A package that already carries a signature (a rebuild of a distribution
  # package, say) has to be stripped first: rpm refuses to add a second one.
  rpm --delsign "$f" >/dev/null 2>&1 || true
  if ! rpmsign --addsign --define "_gpg_name ${SUB_FPR}" "$f" >/dev/null 2>&1; then
    echo "  !! rpmsign failed on $(basename "$f")"; exit 1
  fi
  printf '  %-40s ' "$(basename "$f")"
  rpm -K "$f" 2>&1 | sed 's/.*: //' || true
done

echo
echo "--- build repodata and sign it (repository level) ---"
createrepo_c "$OUT" >/dev/null
gpg --batch --yes --local-user "${SUB_FPR}!" --detach-sign --armor \
    -o "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml"
echo "  repomd.xml.asc = $(wc -c < "$OUT/repodata/repomd.xml.asc" | tr -d ' ') bytes"
gpg --verify "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml" 2>&1 | sed 's/^/    /'

echo
echo "--- the two layers, as a consumer sees them ---"
echo "  metadata: repomd.xml.asc -> $SUB_FPR (per-repo keyring on the consumer)"
echo "  packages: rpmdb key $SUB_FPR (global rpmdb on the consumer)"
find "$OUT" -maxdepth 2 \( -name '*.rpm' -o -name 'repomd.xml*' \) | sort | sed 's/^/  /'
