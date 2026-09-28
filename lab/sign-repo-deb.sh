#!/usr/bin/env bash
#
# Stage S for the deb format: turn the packages stage A produced into a signed
# apt repository.
#
# Format-level, not consumer-level: this produces dists/<suite>/InRelease, and
# apt is simply the program that will read it. It runs in the row's own
# distribution image, so the repository is built with that distribution's own
# tooling.
#
#   env: SIGNING_KEY_B64 - base64 of `gpg --armor --export-secret-subkeys "<fpr>!"`
#        PKGS            - directory holding stage A's out/*.deb
#        OUT             - repository root to build (published as-is)
#        SUITE           - apt suite name, e.g. trixie / resolute / sid
#        LINE            - for the log line only
#
# The keyring source (signed by the root key) is deliberately NOT built here:
# the root secret never enters CI, so that half is a trusted-machine step. This
# only signs the day-to-day source, with this row's subkey.
set -euo pipefail

PKGS="${PKGS:?}"; OUT="${OUT:?}"; SUITE="${SUITE:?}"; LINE="${LINE:-deb}"
KEY_B64="${SIGNING_KEY_B64:-}"
if [ -z "$KEY_B64" ]; then IFS= read -r KEY_B64 || true; fi
[ -n "$KEY_B64" ] || { echo "!! no signing key supplied"; exit 1; }

echo "=== S/deb $LINE ($SUITE) ==="
# Not `. /etc/os-release`: that also defines VERSION and ARCH, which are inputs
# of scripts in this directory. lib-site.sh's os_name carries the story.
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  packages in:  $PKGS"
echo "  repo out:     $OUT"
ls -l "$PKGS" | sed 's/^/    /'

echo
echo "--- tooling (the distribution's own) ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null
apt-get install -y -qq --no-install-recommends gnupg apt-utils gzip </dev/null
echo "  dpkg-deb:    $(dpkg-deb --version | head -1)"
echo "  apt-ftparchive: $(command -v apt-ftparchive)"

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
echo "  subkey = $SUB_FPR  (exactly one, as designed)"

echo
echo "--- assert the root secret is not usable in CI ---"
ROOTFP=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
PROBE=$(mktemp)
if printf 'probe\n' | gpg --batch --local-user "${ROOTFP}!" --detach-sign -o "$PROBE" 2>/dev/null; then
  rm -f "$PROBE"; echo "  !! the root secret can sign here - contradicts the design"; exit 1
fi
rm -f "$PROBE"
echo "  OK: signing as the root key is refused here"

echo
echo "--- lay the real packages into an apt pool ---"
POOL="$OUT/pool/main/q/qmdmm"
mkdir -p "$POOL"
cp -v "$PKGS"/*.deb "$POOL"/ | sed 's/^/  /'
n=$(find "$OUT/pool" -name '*.deb' | wc -l | tr -d ' ')
echo "  $n package(s) in the pool"

echo
echo "--- build + sign the suite ---"
bash "$(dirname "$0")/mkrepo-debian.sh" "$SUB_FPR" "$OUT" "$SUITE" \
     "QMdmm $LINE $SUITE repository" | sed 's/^/  /'

echo
echo "--- what a consumer will fetch ---"
find "$OUT" -type f | sort | sed 's/^/  /'
echo
echo "  InRelease carries:"
gpg --verify "$OUT/dists/$SUITE/InRelease" 2>&1 | sed 's/^/    /'
