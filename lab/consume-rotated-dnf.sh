#!/usr/bin/env bash
#
# Stage B for a line that has been ROTATED: the dnf consumer, against the four
# corners of the rotation.
#
# What the revoked-fixture cells (consume-revoked-dnf.sh) answer is "does this
# consumer consult the revocation certificate". That is one question, asked with
# a key that exists only to be revoked. This cell asks the questions an incident
# plan actually has to answer, on a line whose key really was rotated:
#
#                      key file: NOT refreshed   |  key file: refreshed
#                            (root+outgoing)     |  (root+outgoing[revoked]+incoming)
#   source: frozen old   --------------- 1 ------|------------- 3 ---------------
#                        accepted (control)      |  THE MEASUREMENT
#   source: rebuilt new  --------------- 2 ------|------------- 4 ---------------
#                        refused (the cost)      |  accepted (service restored)
#
#   1. the control. The frozen source has to be readable at all, or nothing
#      below it means anything - FINDINGS 3.7, the same-object discipline.
#   2. the COST of a rotation, and the half nobody had measured: a consumer that
#      has not refreshed its key file cannot read the new source at all. So
#      "rotate and move consumers" is only a plan if the new key file is pushed
#      at the same time as the new signature.
#   3. the LEAK WINDOW: a consumer that HAS refreshed - and therefore holds the
#      revocation certificate - is handed the old source. FINDINGS 10.7 measured
#      this with the fixture key and found dnf accepts it. This re-measures the
#      same thing with a real rotated line key, which is the version an incident
#      actually runs into. Asserted as observed, so the day dnf starts checking
#      revocation this goes red and 10.7 gets revisited.
#   4. service restored. Without it, 1-3 would describe a rotation that leaves
#      the line broken.
#
# Every verdict is "can dnf list a package from this repository", not "did the
# command fail": `dnf makecache` exits 0 even when metadata verification fails
# (FINDINGS 3.2), so the exit code answers a different question.
#
#   env: PAGES, LINE, VERSION, EXPECT_SHA
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

REPO=qmdmm-rotated
REPOFILE=/etc/yum.repos.d/qmdmm-rotated.repo

echo "=== B/rotated (rpm, dnf) - line $LINE, frozen from $VERSION ==="
echo "  $(os_name)"
echo "  $(dnf --version 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 curl ca-certificates </dev/null >/dev/null 2>&1 || true
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- the two key files, and the frozen source ---"
# The frozen source is not a row: it is the repository as this line published it
# immediately before the rotation, captured by lab/rotate-line-local.sh.
fetch "$PAGES/keys/$LINE/qmdmm-packages-before.gpg" "$W/keys/before.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg"        "$W/keys/after.gpg"

root_before=$(key_fpr "$W/keys/before.gpg"); root_after=$(key_fpr "$W/keys/after.gpg")
sub_before=$(live_sub_fpr "$W/keys/before.gpg")
sub_after=$(live_sub_fpr "$W/keys/after.gpg")
dead_before=$(dead_subkeys "$W/keys/before.gpg")
dead_after=$(dead_subkeys "$W/keys/after.gpg")
revoked_in_after=$(dead_sub_fpr "$W/keys/after.gpg")

echo "  before: root $root_before, $dead_before revoked subkey, live subkey $sub_before"
echo "  after:  root $root_after, $dead_after revoked subkey, live subkey $sub_after"
echo "  the subkey the 'after' file carries as revoked: $revoked_in_after"

# Establishing that these really are one line's two states, rather than a
# rotation cell that accidentally compares two unrelated keys. Without this, a
# "refused" anywhere below could be produced by the wrong pair of files.
[ "$root_before" = "$root_after" ] \
  || { echo "  !! the two files do not share a root key"; exit 1; }
[ "$dead_before" = 0 ] \
  || { echo "  !! the 'before' file is not the un-refreshed state"; exit 1; }
[ "$dead_after" = 1 ] \
  || { echo "  !! the 'after' file does not carry exactly one revoked subkey"; exit 1; }
[ "$revoked_in_after" = "$sub_before" ] \
  || { echo "  !! the 'after' file revokes a different subkey than the 'before' file carries"; exit 1; }
[ "$sub_before" != "$sub_after" ] \
  || { echo "  !! the live subkey did not change, so no rotation happened"; exit 1; }
echo "  OK: one root key, the outgoing subkey revoked, the incoming one live"

write_repo() {  # write_repo <key-file> <baseurl>
  cat > "$REPOFILE" <<EOF
[$REPO]
name=QMdmm rotation ($LINE)
baseurl=$2
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$1
EOF
  sed 's/^/  | /' "$REPOFILE"
}

# read_one <label> <key-file> <baseurl> <tagname> -> echoes accepted|refused
read_one() {
  local label="$1" keyf="$2" base="$3" tag="$4" listed
  echo
  echo "--- $label ---"
  write_repo "$keyf" "$base"
  rm -rf /var/cache/dnf /var/cache/libdnf5
  dnf clean all >/dev/null 2>&1 || true
  dnf -y -q makecache > "$W/$tag.log" 2>&1 || true
  echo "  --- what dnf said ---" >&2
  sed 's/^/    /' "$W/$tag.log" >&2
  listed=$(dnf_packages "$REPO" "$W" || true)
  if [ -n "$listed" ]; then
    echo "  dnf lists: $(printf '%s' "$listed" | tr '\n' ' ')" >&2
    echo "  VERDICT: accepted" >&2
    printf 'accepted'
  else
    echo "  VERDICT: refused" >&2
    printf 'refused'
  fi
}

fail() { echo "  !! $1"; exit 1; }

v=$(read_one "1) frozen source, key file NOT refreshed  -> must be accepted" \
             "$W/keys/before.gpg" "$PAGES/$LINE-revoked" r1)
[ "$v" = accepted ] || fail "the control was refused, so nothing below would mean anything"

v=$(read_one "2) rebuilt source, key file NOT refreshed  -> must be refused" \
             "$W/keys/before.gpg" "$PAGES/$LINE/$VERSION" r2)
[ "$v" = refused ] || fail "a consumer that has not refreshed its key can read the new source"

v=$(read_one "3) frozen source, key file refreshed      -> the measurement" \
             "$W/keys/after.gpg" "$PAGES/$LINE-revoked" r3)
if [ "$v" = accepted ]; then
  echo "  -> the revoked outgoing subkey still signs for dnf: rotation does NOT"
  echo "     stop this consumer, which is FINDINGS 10.7 on a real rotated line"
elif [ "$v" = refused ]; then
  echo "  !! dnf REFUSED it - it now consults revocation, so FINDINGS 10.7 is out"
  echo "     of date and this cell should be flipped; see the note in"
  echo "     consume-revoked-dnf.sh for the same assertion."
  fail "the verdict changed from the recorded one (accepted)"
else
  fail "unreadable verdict: $v"
fi

v=$(read_one "4) rebuilt source, key file refreshed     -> must be accepted" \
             "$W/keys/after.gpg" "$PAGES/$LINE/$VERSION" r4)
[ "$v" = accepted ] || fail "the rotation left the line broken for a refreshed consumer"

echo
echo "=== B/rotated (rpm, dnf, $LINE): PASS ==="
