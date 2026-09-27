#!/usr/bin/env bash
#
# Consumer-side check, run inside a clean fedora container.
# Public keys are fetched from Pages only - this job holds no secret at all.
#
# What is checked: dnf's repository-metadata signature (repo_gpgcheck).
# In dnf5 that metadata is verified against a *per-repository* keyring, so
# only the key listed in this repo's gpgkey= can sign it.
#
#   A. day-to-day source + packages key (root + this line's subkey) -> must PASS
#   B. day-to-day source + root key (primary only)                  -> must FAIL
#
# Package-level gpgcheck (the rpm inside) is a different story: it goes through
# the *global rpmdb*, so that key has to be `rpm --import`ed. Kept out of the
# assertions here on purpose.
set -euo pipefail

PAGES="${LAB_PAGES:?}"
W=/w/verify-fedora

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  dnf: $(dnf --version | head -1)"

echo
echo "=== dependencies ==="
dnf install -y -q gnupg2 ca-certificates curl

fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsSL --max-time 30 "$url" -o "$out" && return 0
    echo "    fetch $url failed (attempt $i), retrying in 5s"; sleep 5
  done
  echo "    !! giving up: $url"; return 1
}

echo
echo "=== fetch public keys from Pages ==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"            "$W/root.gpg"
fetch "$PAGES/keys/fedora/qmdmm-packages.gpg" "$W/packages.gpg"
for f in "$W/root.gpg" "$W/packages.gpg"; do
  printf '  %-14s ' "$(basename "$f")"
  gpg --with-colons --import-options show-only --import "$f" 2>/dev/null \
    | awk -F: '/^pub:/{p+=1} /^sub:/{s+=1} END{printf "pub=%d sub=%d\n", p+0, s+0}'
done

mk_repo() {
  local tag="$1" keyfile="$2" d
  d="/tmp/repos-$tag"; rm -rf "$d"; mkdir -p "$d"
  cat > "$d/lab.repo" <<EOF
[lab]
name=QMdmm signing lab ($tag)
baseurl=$PAGES/repo/fedora/daily
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$keyfile
EOF
  echo "$d"
}

run_scenario() {
  local name="$1" keyfile="$2" expect="$3" d out rc
  d=$(mk_repo "$(basename "$keyfile" .gpg)" "$keyfile")
  printf '\n--- %s (key=%s, expect %s)\n' "$name" "$(basename "$keyfile")" "$expect"
  rm -rf /var/cache/dnf /tmp/dnfcache
  set +e
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir=/tmp/dnfcache makecache 2>&1)
  rc=$?
  set -e
  echo "$out" | grep -iE 'signature|gpg|error|fail|metadata|repo' | head -8 | sed 's/^/    /' || true
  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ]; then echo "    => PASS"
    else echo "    => FAIL (expected PASS, got rc=$rc)"; return 1; fi
  else
    if [ $rc -ne 0 ]; then echo "    => REJECTED (rc=$rc)"
    else echo "    => FAIL (expected rejection, but it was accepted - isolation is broken!)"; return 1; fi
  fi
  echo "    (per-repo keyring dnf created for this repo:)"
  find /tmp/dnfcache -maxdepth 2 -name 'pubring*' 2>/dev/null | sed 's/^/      /' || true
}

echo
echo "=============================================================="
echo "  rpm: repository-metadata signature (repo_gpgcheck)"
echo "=============================================================="
run_scenario "A. day-to-day source + packages key (root + subkey)" "$W/packages.gpg" PASS
run_scenario "B. day-to-day source + root key (primary only)"      "$W/root.gpg"     FAIL

echo
echo "=============================================================="
echo "  passed: only this line's subkey can sign this repo's metadata"
echo "=============================================================="
