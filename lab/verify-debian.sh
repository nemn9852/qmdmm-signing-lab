#!/usr/bin/env bash
#
# Consumer-side check, run inside a clean debian:sid container.
# Public keys are fetched from Pages only - this job holds no secret at all.
#
# The published layout is one directory per distro, so a consumer's
# sources.list can point straight at it:
#
#   deb [signed-by=.../qmdmm-packages.gpg] <pages>/debian sid main
#
# The keyring source lives next door at <pages>/debian-keyring: the two sources
# have to carry different Signed-By files, so they cannot share a directory.
#
# Cells A-D are the isolation matrix; E is what a rotation leaves behind:
#   A. keyring source (root-signed)  + root key      -> must PASS
#   B. day-to-day source (subkey)    + packages key  -> must PASS
#   C. day-to-day source (subkey)    + root key      -> must FAIL  <- the point
#   D. keyring source (root-signed)  + packages key  -> must PASS
#   E. source signed by a REVOKED subkey, + refreshed packages key -> must FAIL
set -euo pipefail

PAGES="${LAB_PAGES:?}"
ROOT_FPR="${ROOT_FPR:?}"
SUITE="${SUITE:-sid}"
LINE="${LINE:-debian}"
W=/w/verify-debian

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg: $(gpg --version | head -1)"
echo "  line=$LINE suite=$SUITE"

echo
echo "=== dependencies ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    gnupg gpgv apt-utils gzip curl ca-certificates

fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsSL --max-time 30 "$url" -o "$out" && return 0
    echo "    fetch $url failed (attempt $i), retrying in 5s"; sleep 5
  done
  echo "    !! giving up: $url"; return 1
}

echo
echo "=== wait for this publish to be live (branch deploys are async) ==="
# shellcheck source=lib-site.sh
source /w/lab/lib-site.sh
wait_for_publish "$PAGES" "${EXPECT_SHA:?EXPECT_SHA not set}"

echo
echo "=== fetch public keys from Pages (the only channel a consumer has) ==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"            "$W/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg"  "$W/packages.gpg"
ls -l "$W"/*.gpg | sed 's/^/  /'
echo "  --- what each file carries ---"
for f in "$W/root.gpg" "$W/packages.gpg"; do
  printf '  %-14s ' "$(basename "$f")"
  gpg --with-colons --import-options show-only --import "$f" 2>/dev/null \
    | awk -F: '/^pub:/{p+=1} /^sub:/{s+=1} END{printf "pub=%d sub=%d\n", p+0, s+0}'
done

echo "  --- root fingerprint as the consumer sees it (expect $ROOT_FPR) ---"
TMPH=$(mktemp -d); chmod 700 "$TMPH"
GNUPGHOME="$TMPH" gpg --batch --import "$W/root.gpg" 2>/dev/null
GNUPGHOME="$TMPH" gpg --with-colons --list-keys 2>/dev/null \
  | awk -F: '/^fpr:/{print "    "$10; exit}'
rm -rf "$TMPH"

run_scenario() {
  local name="$1" key="$2" url="$3" expect="$4"
  printf '\n--- %s\n' "$name"
  printf '    source=%s  key=%s  expect=%s\n' "$url" "$(basename "$key")" "$expect"
  cat > /tmp/sources.list <<EOF
deb [signed-by=$key] $url $SUITE main
EOF
  rm -rf /tmp/lists /tmp/cache
  mkdir -p /tmp/lists/partial /tmp/cache/archives/partial /tmp/empty
  local out rc
  set +e
  out=$(apt-get -o Dir::Etc::sourcelist=/tmp/sources.list \
              -o Dir::Etc::sourceparts=/tmp/empty \
              -o Dir::Etc::trusted=/dev/null \
              -o Dir::Etc::trustedparts=/tmp/empty \
              -o Dir::State::lists=/tmp/lists \
              -o Dir::Cache=/tmp/cache \
              -o Acquire::Retries=0 \
              -o APT::Sandbox::User=root \
              update 2>&1)
  rc=$?
  set -e
  echo "$out" | grep -E '^(Err|E:|W:|Get|Hit)' | sed 's/^/    /' || true
  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ]; then echo "    => PASS"
    else echo "    => FAIL (expected PASS, got rc=$rc)"; return 1; fi
  else
    if [ $rc -ne 0 ]; then echo "    => REJECTED (rc=$rc)"
    else echo "    => FAIL (expected rejection, but it was accepted - isolation is broken!)"; return 1; fi
  fi
}

echo
echo "=============================================================="
echo "  debian: isolation matrix"
echo "=============================================================="
run_scenario "A. keyring source (root-signed) + root key"      "$W/root.gpg"     "$PAGES/$LINE-keyring" PASS
run_scenario "B. day-to-day source (subkey)   + packages key"  "$W/packages.gpg" "$PAGES/$LINE"         PASS
run_scenario "C. day-to-day source (subkey)   + root key"      "$W/root.gpg"     "$PAGES/$LINE"         FAIL
run_scenario "D. keyring source (root-signed) + packages key"  "$W/packages.gpg" "$PAGES/$LINE-keyring" PASS

echo
echo "=============================================================="
echo "  after a rotation: is a revoked subkey's old output still accepted?"
echo "=============================================================="
run_scenario "E. source signed by the REVOKED subkey + current packages key" \
             "$W/packages.gpg" "$PAGES/$LINE-revoked" FAIL

echo
echo "=============================================================="
echo "  install the keyring package: does one .deb configure BOTH sources?"
echo "=============================================================="
# This is the shape Debian's wiki blesses: a keyring package MUST ship the
# certificates under /usr/share/keyrings and MAY also ship sources.list.d.
# Nothing here is protected by a .deb signature - apt does not review those at
# all - but by the fact that the package is served from the root-signed keyring
# source, whose InRelease only the root key can sign.
KEYRING_SRC="$PAGES/$LINE-keyring"
fetch "$KEYRING_SRC/dists/$SUITE/main/binary-all/Packages" "$W/keyring-index"
DEBPATH=$(awk '/^Filename:/{print $2; exit}' "$W/keyring-index")
echo "  package: $DEBPATH"
fetch "$KEYRING_SRC/$DEBPATH" "$W/keyring.deb"

if ! dpkg -i "$W/keyring.deb" > /tmp/dpkg.log 2>&1; then
  echo "  !! dpkg -i failed"; tail -15 /tmp/dpkg.log | sed 's/^/    /'; exit 1
fi
echo "  --- what it dropped ---"
ls -l /usr/share/keyrings/qmdmm-*.gpg /etc/apt/sources.list.d/qmdmm.sources 2>&1 | sed 's/^/    /'
echo "  --- the sources it wrote ---"
sed 's/^/    /' /etc/apt/sources.list.d/qmdmm.sources

# Keep the assertion about OUR sources: move the distro's own list aside.
find /etc/apt/sources.list.d -maxdepth 1 -name 'debian.sources' -exec mv {} /tmp/debian.sources.off \; 2>/dev/null || true
rm -rf /var/lib/apt/lists/*
echo "  --- now a plain apt-get update, no -o overrides ---"
set +e
out=$(apt-get update 2>&1); rc=$?
set -e
echo "$out" | grep -E '^(Err|E:|W:|Get|Hit)' | sed 's/^/    /' || true
if [ $rc -eq 0 ]; then echo "    => PASS: both sources accepted straight out of the box"
else echo "    => FAIL: a consumer that installed the keyring package still cannot update"; exit 1; fi

echo
echo "=============================================================="
echo "  all assertions passed: the keyring source only answers to root;"
echo "  this line's subkey cannot sign anything that replaces the trust root"
echo "=============================================================="
