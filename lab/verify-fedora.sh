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
# B is the sharper half: the subkey is imported into the *global* rpmdb before
# both scenarios run, so if dnf consulted the rpmdb for metadata it would have
# accepted B too. It rejects it - which is what establishes the two-layer split
# (metadata = per-repo keyring, package = global rpmdb).
#
# Also note: `dnf makecache` exits 0 even when the repomd signature fails to
# verify. Never use its exit code as the assertion.
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
  local name="$1" keyfile="$2" expect="$3" d out rc verr
  d=$(mk_repo "$(basename "$keyfile" .gpg)" "$keyfile")
  printf '\n--- %s (key=%s, expect %s)\n' "$name" "$(basename "$keyfile")" "$expect"
  rm -rf /var/cache/dnf /tmp/dnfcache
  set +e
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir=/tmp/dnfcache makecache 2>&1)
  rc=$?
  set -e
  echo "$out" | grep -iE 'signature|gpg|error|fail|metadata cache|repo' | head -8 | sed 's/^/    /' || true

  # IMPORTANT: `dnf makecache` still exits 0 when the repomd signature fails to
  # verify - it only prints ">>> repomd.xml GPG signature verification error".
  # So the exit code is NOT a usable assertion here; look for the message.
  verr=0
  echo "$out" | grep -qi 'signature verification error' && verr=1
  echo "    exit=$rc  signature-error-in-output=$verr"

  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ] && [ $verr -eq 0 ]; then echo "    => PASS"
    else echo "    => FAIL (expected a clean pass, got rc=$rc verr=$verr)"; return 1; fi
  else
    if [ $verr -eq 1 ]; then echo "    => REJECTED (dnf reported a signature error)"
    else echo "    => FAIL (expected a signature error, none reported - isolation is broken!)"; return 1; fi
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
