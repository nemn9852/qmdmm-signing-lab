#!/usr/bin/env bash
#
# Stage B for a line that has been ROTATED: the dnf consumer, against the four
# corners of the rotation and then against the counterfactual that decides what
# to publish afterwards.
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
# And then the counterfactual, on the same two sources, with a THIRD key file:
# the refreshed one MINUS the revoked subkey (keys/<line>/...-pruned.gpg).
#
#   source: frozen old   ------------- 5 -->  must be refused
#   source: rebuilt new  ------------- 6 -->  must be accepted
#
#   5-6. what pins corner 3's cause. 3 and 2 together already imply it - dnf
#      refuses when the signing key is absent (2) and accepts when a revoked one
#      is present (3) - so on rpm it is *carrying* the outgoing subkey that
#      keeps the compromised key signing. But that is an inference, and "publish
#      the rotated key file without it" is a recommendation about an artifact
#      PEOPLE WILL HAND OUT, so 5 and 6 measure it instead of inferring it: 5 is
#      the window closing, 6 is the half that says closing it costs a consumer
#      nothing. See FINDINGS 10.9.
#
# Every verdict is "can dnf list a package from this repository", not "did the
# command fail": `dnf makecache` exits 0 even when metadata verification fails
# (FINDINGS 3.2), so the exit code answers a different question. The same
# suspicion applies to the log, so this cell also MEASURES whether dnf's output
# distinguishes 1 from 2 at all - it does on dnf4, it does not on dnf5, where
# both readings print "Metadata cache created." (FINDINGS 3.15).
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
echo "--- the three key files, and the frozen source ---"
# The frozen source is not a row: it is the repository as this line published it
# immediately before the rotation, captured by lab/rotate-line-local.sh.
fetch "$PAGES/keys/$LINE/qmdmm-packages-before.gpg" "$W/keys/before.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg"        "$W/keys/after.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages-pruned.gpg" "$W/keys/pruned.gpg"

root_before=$(key_fpr "$W/keys/before.gpg"); root_after=$(key_fpr "$W/keys/after.gpg")
sub_before=$(live_sub_fpr "$W/keys/before.gpg")
sub_after=$(live_sub_fpr "$W/keys/after.gpg")
dead_before=$(dead_subkeys "$W/keys/before.gpg")
dead_after=$(dead_subkeys "$W/keys/after.gpg")
revoked_in_after=$(dead_sub_fpr "$W/keys/after.gpg")
root_pruned=$(key_fpr "$W/keys/pruned.gpg")
sub_pruned=$(live_sub_fpr "$W/keys/pruned.gpg")
dead_pruned=$(dead_subkeys "$W/keys/pruned.gpg")

echo "  before: root $root_before, $dead_before revoked subkey, live subkey $sub_before"
echo "  after:  root $root_after, $dead_after revoked subkey, live subkey $sub_after"
echo "  the subkey the 'after' file carries as revoked: $revoked_in_after"
echo "  pruned: root $root_pruned, $dead_pruned revoked subkey, live subkey $sub_pruned"

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
# And the pruned file has to be that SAME root and that SAME incoming subkey,
# with the outgoing one simply gone. Otherwise a refusal in 5 below could be
# produced by an unrelated key file rather than by the removal, which is the
# whole reading.
[ "$root_pruned" = "$root_after" ] \
  || { echo "  !! the pruned file is not this line's root key"; exit 1; }
[ "$sub_pruned" = "$sub_after" ] \
  || { echo "  !! the pruned file does not carry the incoming subkey"; exit 1; }
[ "$dead_pruned" = 0 ] \
  || { echo "  !! the pruned file still carries a revoked subkey"; exit 1; }
echo "  OK: one root key, the outgoing subkey revoked, the incoming one live"
echo "  OK: the pruned file is that same key file with the outgoing subkey dropped"

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

# read_one <label> <key-file> <baseurl> <tag>
#
# The verdict goes to $W/<tag>.verdict and everything a human reads goes to
# stdout. NOT "echo the verdict and capture it", which is what this did first:
# write_repo below displays the .repo file it just wrote, that display went into
# the captured value along with the verdict, and the control read as refused
# while the log one line above it said "dnf lists: qmdmm-6 qmdmm-6-devel ...".
# FINDINGS 3.12 is this family - a value captured out of a function that also
# talks to the terminal - and a file is harder to contaminate than a pipe.
read_one() {
  local label="$1" keyf="$2" base="$3" tag="$4" listed
  echo
  echo "--- $label ---"
  write_repo "$keyf" "$base"
  rm -rf /var/cache/dnf /var/cache/libdnf5
  dnf clean all >/dev/null 2>&1 || true
  dnf -y -q makecache > "$W/$tag.log" 2>&1 || true
  echo "  --- what dnf said ---"
  sed 's/^/    /' "$W/$tag.log"
  listed=$(dnf_packages "$REPO" "$W" || true)
  if [ -n "$listed" ]; then
    echo "  dnf lists: $(printf '%s' "$listed" | tr '\n' ' ')"
    printf 'accepted' > "$W/$tag.verdict"
  else
    printf 'refused' > "$W/$tag.verdict"
  fi
  echo "  VERDICT: $(cat "$W/$tag.verdict")"
}

fail() { echo "  !! $1"; exit 1; }

# expected <tag> <wanted> <why>
#
# Printed as "reading <tag>" rather than "corner <tag>": the diagram at the top
# has four corners, and readings 5 and 6 are not among them - they are the
# counterfactual run with a different key file.
expected() {
  local got
  got=$(cat "$W/$1.verdict" 2>/dev/null || true)
  case "$got" in
    accepted|refused) ;;
    # No verdict is a failure, never a "refused": reporting a consumer refusing
    # something when the reading never completed would read as a finding.
    *) fail "no verdict was recorded for '$1' - the reading did not finish" ;;
  esac
  [ "$got" = "$2" ] || fail "expected '$2', got '$got': $3"
  echo "  reading $1: $got, as required"
}

read_one "1) frozen source, key file NOT refreshed  -> must be accepted" \
         "$W/keys/before.gpg" "$PAGES/$LINE-revoked" r1
expected r1 accepted "the control was refused, so nothing below would mean anything"

read_one "2) rebuilt source, key file NOT refreshed  -> must be refused" \
         "$W/keys/before.gpg" "$PAGES/$LINE/$VERSION" r2
expected r2 refused "a consumer that has not refreshed its key can read the new source"

# Readings 1 and 2 differ in one thing only - whether the key file can verify the
# source - so the two log files are a controlled pair, and what they are worth is
# a measurement rather than a hope. On dnf4 the refusal is named; on dnf5 the two
# are byte-identical, "Metadata cache created." included, so on that consumer
# "dnf said nothing" is not evidence that anything verified. That matters because
# several cells in this lab (and one control in consume-revoked-dnf.sh, on the
# empty rpm fixture) have read exactly that as acceptance. FINDINGS 3.15.
echo
echo "--- does dnf's own output distinguish reading 1 from reading 2? ---"
if diff -q "$W/r1.log" "$W/r2.log" >/dev/null 2>&1; then
  echo "  no: they printed the same thing. The refusal is silent here, so both"
  echo "  verdicts above rest on the package listing - which is where they are"
  echo "  taken from - and nothing in this cell greps the log for an answer."
else
  echo "  yes: the refusal is named, and reading 2 added:"
  diff "$W/r1.log" "$W/r2.log" | grep '^>' | sed 's/^> */    /' || true
fi

read_one "3) frozen source, key file refreshed      -> the measurement" \
         "$W/keys/after.gpg" "$PAGES/$LINE-revoked" r3
v=$(cat "$W/r3.verdict" 2>/dev/null || true)
if [ "$v" = accepted ]; then
  echo "  -> the revoked outgoing subkey still signs for dnf: rotation does NOT"
  echo "     stop this consumer, which is FINDINGS 10.7 on a real rotated line"
elif [ "$v" = refused ]; then
  echo "  !! dnf REFUSED it - it now consults revocation, so FINDINGS 10.7 is out"
  echo "     of date and this cell should be flipped; see the note in"
  echo "     consume-revoked-dnf.sh for the same assertion."
  fail "the verdict changed from the recorded one (accepted)"
else
  fail "no verdict was recorded for corner 3 - the reading did not finish"
fi

read_one "4) rebuilt source, key file refreshed     -> must be accepted" \
         "$W/keys/after.gpg" "$PAGES/$LINE/$VERSION" r4
expected r4 accepted "the rotation left the line broken for a refreshed consumer"

echo
echo "=== and the counterfactual: the refreshed key file, minus the outgoing subkey ==="
echo "  (the recommendation this cell exists to support is \"publish it without the"
echo "   revoked subkey\" - so the removal has to be measured, not inferred)"

read_one "5) frozen source, key file WITHOUT the outgoing subkey -> must be refused" \
         "$W/keys/pruned.gpg" "$PAGES/$LINE-revoked" r5
expected r5 refused "dnf still accepted the old source after the outgoing subkey was dropped, so that subkey's presence was not what made reading 3 accept it"

read_one "6) rebuilt source, same key file                      -> must be accepted" \
         "$W/keys/pruned.gpg" "$PAGES/$LINE/$VERSION" r6
expected r6 accepted "dropping the outgoing subkey left the CURRENT source unreadable, so the removal costs a consumer something"

echo
echo "--- what 3, 5 and 6 say together ---"
echo "  3: with the outgoing subkey carried as revoked, the frozen source is ACCEPTED"
echo "  5: with it dropped, the same source is refused"
echo "  6: dropping it costs a consumer nothing - the current source still verifies"
echo "  -> on rpm, a revoked subkey being PRESENT in the published key file is what"
echo "     keeps it signing; publishing the rotated file without it closes the"
echo "     window at no cost (FINDINGS 10.9). On debian the same choice is a"
echo "     trade-off, because there the outgoing subkey is what turns \"unknown"
echo "     key\" into \"revoked\" for the consumer."

echo
echo "=== B/rotated (rpm, dnf, $LINE): PASS ==="
