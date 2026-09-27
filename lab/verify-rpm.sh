#!/usr/bin/env bash
#
# Consumer-side check, run inside a clean dnf-based container (fedora / rocky /
# alma all use this script). Public keys come from Pages only - this job holds
# no secret at all.
#
# What is checked: dnf's repository-metadata signature (repo_gpgcheck).
# In dnf5 that metadata is verified against a *per-repository* keyring, so only
# the key listed in this repo's gpgkey= can sign it.
#
#   A. day-to-day source + packages key (root + this line's subkey) -> must PASS
#   B. day-to-day source + root key (primary only)                  -> must FAIL
#
# B is the sharper half: the subkey is imported into the *global* rpmdb before
# both scenarios run, so if dnf consulted the rpmdb for metadata it would have
# accepted B too. It rejects it - which is what establishes the two-layer split
# (metadata = per-repo keyring, package = global rpmdb).
#
# EXPECT_METADATA_REJECTED=1 says: on this rpm/dnf, metadata verification is
# known not to work at all (fedora:43, rpm 6.0.2 / dnf5 5.2.18 - see
# FINDINGS.md section 4). That inverts the A assertion, so a known-broken
# toolchain does not leave a job red forever and train everyone to ignore it:
#
#   A rejected  -> PASS   (the known limitation, still exactly as documented)
#   A accepted  -> FAIL   (the limitation is gone; drop the flag and let A and
#                          B assert normally again)
#
# B is skipped under the flag: if A already cannot be verified, B proves nothing.
#
# Also note: `dnf makecache` exits 0 even when the repomd signature fails to
# verify. Never use its exit code as the assertion.
set -euo pipefail

PAGES="${LAB_PAGES:?}"
LINE="${LINE:?}"
EXPECT_REJECTED="${EXPECT_METADATA_REJECTED:-0}"
W=/w/verify-rpm

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  line: $LINE"
echo "  rpm:  $(rpm --version)"
echo "  dnf:  $(dnf --version | head -1)"
echo "  gpg:  $(gpg --version | head -1)"
echo "  rpm's OpenPGP backend: $(rpm --eval '%_openpgp_sign' 2>/dev/null || echo '<unset>')"

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
echo "=== wait for this publish to be live (branch deploys are async) ==="
# shellcheck source=lib-site.sh
source /w/lab/lib-site.sh
wait_for_publish "$PAGES" "${EXPECT_SHA:?EXPECT_SHA not set}"

echo
echo "=== fetch public keys from Pages ==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"        "$W/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/packages.gpg"
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
baseurl=$PAGES/$LINE
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

  verr=0
  echo "$out" | grep -qi 'signature verification error' && verr=1
  echo "    exit=$rc  signature-error-in-output=$verr"

  if [ "$expect" = PASS ]; then
    if [ "$EXPECT_REJECTED" = 1 ]; then
      # inverted: this toolchain is documented as unable to verify metadata
      if [ $verr -eq 1 ]; then
        echo "    => KNOWN LIMITATION, still as documented (metadata rejected on this rpm/dnf)"
      else
        echo "    => FAIL (expected the documented rejection, but it verified!)"
        echo "       The known fedora:43 limitation appears to be FIXED."
        echo "       Drop EXPECT_METADATA_REJECTED for this line so A and B assert normally."
        return 1
      fi
    else
      if [ $rc -eq 0 ] && [ $verr -eq 0 ]; then echo "    => PASS"
      else echo "    => FAIL (expected a clean pass, got rc=$rc verr=$verr)"; return 1; fi
    fi
  else
    if [ $verr -eq 1 ]; then echo "    => REJECTED (dnf reported a signature error)"
    else echo "    => FAIL (expected a signature error, none reported - isolation is broken!)"; return 1; fi
  fi
  echo "    (per-repo keyring dnf created for this repo:)"
  find /tmp/dnfcache -maxdepth 2 -name 'pubring*' 2>/dev/null | sed 's/^/      /' || true
}

echo
echo "=============================================================="
echo "  $LINE: repository-metadata signature (repo_gpgcheck)"
echo "=============================================================="
run_scenario "A. day-to-day source + packages key (root + subkey)" "$W/packages.gpg" PASS
if [ "$EXPECT_REJECTED" = 1 ]; then
  echo
  echo "  B skipped: with metadata verification unusable on this rpm/dnf, the"
  echo "  two-layer check (metadata=per-repo keyring vs package=global rpmdb)"
  echo "  cannot be concluded here. It is asserted on the EL lines."
else
  run_scenario "B. day-to-day source + root key (primary only)"    "$W/root.gpg"     FAIL
fi

echo
echo "=============================================================="
if [ "$EXPECT_REJECTED" = 1 ]; then
  echo "  passed: metadata verification still fails exactly as documented"
  echo "  (rpm 6 / dnf5 on fedora:43 - FINDINGS.md section 4.1)"
else
  echo "  passed: only this line's subkey can sign this repo's metadata"
fi
echo "=============================================================="
