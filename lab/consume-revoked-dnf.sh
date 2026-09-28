#!/usr/bin/env bash
#
# Stage B for the rpm format: does dnf refuse metadata signed by a key that has
# since been revoked?
#
# FINDINGS 3.1 recorded that revocation is only as good as the verifier, and 10.7
# recorded that this lab had demonstrated it against `gpgv` (apt's backend) and
# measured nothing for dnf or pacman. This cell measures dnf.
#
# The design is the same-object control that 3.7 asks for, taken to its tightest
# form here: ONE artifact, ONE repository configuration, and the only thing that
# differs between the two halves is which public state of the signing key the
# consumer was given.
#
#   A. gpgkey = the key as it looked BEFORE the revocation -> must be accepted
#   B. gpgkey = the same key WITH the revocation certificate -> must be refused
#
# If B were run without A, a refusal could be caused by anything - a bad URL, a
# missing file - and would still look like revocation working. A is what makes
# B mean something.
#
#   env: PAGES, EXPECT_SHA
set -euo pipefail

PAGES="${PAGES:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

REPO=qmdmm-fixture
REPOFILE=/etc/yum.repos.d/qmdmm-fixture.repo

write_repo() {  # write_repo <key-file>
  cat > "$REPOFILE" <<EOF
[$REPO]
name=QMdmm revocation fixture
baseurl=$PAGES/revoked-rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$1
EOF
  sed 's/^/  | /' "$REPOFILE"
}

echo "=== B/revoked (rpm, dnf) ==="
# Not `. /etc/os-release` - see FINDINGS 3.10.
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  $(dnf --version 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 curl ca-certificates </dev/null >/dev/null 2>&1 || true
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- the two public states of one key ---"
fetch "$PAGES/keys/revoked-fixture-before.gpg" "$W/keys/before.gpg"
fetch "$PAGES/keys/revoked-fixture.gpg"        "$W/keys/after.gpg"
sub_before=$(first_sub_fpr "$W/keys/before.gpg")
sub_after=$(first_sub_fpr "$W/keys/after.gpg")
echo "  before: subkey $sub_before"
echo "  after:  subkey $sub_after"
[ "$sub_before" = "$sub_after" ] \
  || { echo "  !! the two files are not two states of the same key"; exit 1; }
echo "  OK: same key, two states"

echo
echo "--- A) the pre-revocation key must accept the repository ---"
write_repo "$W/keys/before.gpg"
rm -rf /var/cache/dnf /var/cache/libdnf5; dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/a.log" 2>&1 || true
echo "  --- what dnf said ---"
sed 's/^/    /' "$W/a.log"
# The mirror of the assertion in the second half: no signature complaint here.
# That is the entire difference between the two halves - one artifact, one
# configuration, one key file apart.
if grep -qiE 'signature verification error|GPG check FAILED|Bad PGP signature|Signing key not found' "$W/a.log"; then
  echo "  !! the control was refused, so the second half would mean nothing"
  exit 1
fi
echo "  OK: accepted (an empty repository, as designed - the metadata verified)"

echo
echo "--- B) the SAME key, with its revocation certificate, must refuse it ---"
write_repo "$W/keys/after.gpg"
rm -rf /var/cache/dnf /var/cache/libdnf5; dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/b.log" 2>&1 || true
echo "  --- what dnf said ---"
sed 's/^/    /' "$W/b.log"
# Two assertions, because either one alone can be satisfied for the wrong reason.
# "dnf lists no package" is true of an EMPTY repository whether or not the
# signature was accepted - and this fixture is empty on purpose, so that check on
# its own would pass with revocation doing nothing at all. The refusal has to be
# visible in what dnf says about the signature; only then does the second
# assertion mean what it looks like it means.
if ! grep -qiE 'signature verification error|GPG check FAILED|Bad PGP signature|Signing key not found' "$W/b.log"; then
  echo "  !! dnf reported no signature problem - so any refusal here has another cause"
  exit 1
fi
mapfile -t seen < <(dnf_packages "$REPO" "$W" || true)
if [ "${#seen[@]}" -ge 1 ]; then
  echo "  !! dnf accepted metadata signed by a revoked key: ${seen[*]}"; exit 1
fi
echo "  OK: refused, and it said why"

echo
echo "=== B/revoked (rpm, dnf): PASS ==="
