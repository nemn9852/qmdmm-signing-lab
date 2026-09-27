#!/usr/bin/env bash
#
# Consumer-side check, run inside a clean debian:sid container.
# Public keys are fetched from Pages only - this job holds no secret at all.
#
# 4-cell isolation matrix:
#   A. keyring source (root-signed)  + root key      -> must PASS
#   B. day-to-day source (subkey)    + packages key  -> must PASS
#   C. day-to-day source (subkey)    + root key      -> must FAIL  <- the whole point
#   D. keyring source (root-signed)  + packages key  -> must PASS
#
# C is what makes the scheme worth anything: a leaked per-distro subkey must
# not be able to forge the source that carries the trust root.
set -euo pipefail

PAGES="${LAB_PAGES:?}"
ROOT_FPR="${ROOT_FPR:?}"
SUB_FPR="${SUB_FPR:?}"
W=/w/verify-debian

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg: $(gpg --version | head -1)"

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
echo "=== fetch public keys from Pages (the only channel a consumer has) ==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"            "$W/root.gpg"
fetch "$PAGES/keys/debian/qmdmm-packages.gpg" "$W/packages.gpg"
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
  local name="$1" key="$2" path="$3" expect="$4"
  printf '\n--- %s\n' "$name"
  printf '    source=%s  key=%s  expect=%s\n' "$path" "$(basename "$key")" "$expect"
  cat > /tmp/sources.list <<EOF
deb [signed-by=$key] $PAGES/repo/debian/$path stable main
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
echo "  debian: 4-cell isolation matrix"
echo "=============================================================="
run_scenario "A. keyring source (root-signed) + root key"     "$W/root.gpg"     "keyring" PASS
run_scenario "B. day-to-day source (subkey)   + packages key" "$W/packages.gpg" "daily"   PASS
run_scenario "C. day-to-day source (subkey)   + root key"     "$W/root.gpg"     "daily"   FAIL
run_scenario "D. keyring source (root-signed) + packages key" "$W/packages.gpg" "keyring" PASS

echo
echo "=============================================================="
echo "  all assertions passed: the keyring source only answers to root;"
echo "  this line's subkey cannot sign anything that replaces the trust root"
echo "=============================================================="
