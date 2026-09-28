#!/usr/bin/env bash
#
# Stage B for a line that has been ROTATED: the pacman consumer, against the
# four corners of the rotation. The counterpart of consume-rotated-dnf.sh; read
# that file's header for what each corner is and why.
#
# One structural difference, and it is pacman's own doing. dnf gets its trust
# per repository, from the `gpgkey=` line, so the four corners there are four
# independent configurations. pacman has no per-repository trust scope at all
# (FINDINGS 6): trust is one global keyring, granted with `pacman-key
# --lsign-key`. So here the four corners are a SEQUENCE - the first two with the
# keyring a consumer has before it refreshes, the last two after - and the order
# cannot be changed, because once the revocation certificate is in the keyring
# there is no way to un-see it.
#
#                      keyring: NOT refreshed     |  keyring: refreshed
#                            (outgoing lsign'd)   |  (+cert, incoming lsign'd)
#   source: frozen old   --------------- 1 ------|------------- 3 ---------------
#                        accepted (control)      |  THE MEASUREMENT
#   source: rebuilt new  --------------- 2 ------|------------- 4 ---------------
#                        refused (the cost)      |  accepted (service restored)
#
# FINDINGS 10.7 recorded that pacman refuses a revoked signer while dnf accepts.
# Corner 3 is that finding re-measured on a real rotated line; corner 2 is the
# cost of the rotation; corner 4 is what makes it a rotation rather than an
# outage.
#
#   env: PAGES, LINE, VERSION, EXPECT_SHA
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

REPO=lab                                   # stage S always names the db lab.db
CONF=/etc/pacman.conf
KR=/etc/pacman.d/gnupg

echo "=== B/rotated (pacman) - line $LINE, frozen from $VERSION ==="
echo "  $(os_name)"
echo "  $(pacman --version | head -1)"

echo
echo "--- tooling ---"
if ! grep -qE '^\s*Server' /etc/pacman.d/mirrorlist; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
pacman_tools
command -v gpg >/dev/null || { echo "  !! gpg is missing"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1
# --lsign-key signs with the keyring's own master key, so it must have one.
if ! gpg --homedir "$KR" --list-secret-keys 2>/dev/null | grep -q '^sec'; then
  echo "  (the pacman keyring has no secret key; creating one)"
  pacman-key --init
fi
# From here on pacman.conf is rewritten per reading, so keep the original.
cp "$CONF" "$W/pacman.conf.orig"

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- the two key files, and the frozen source ---"
fetch "$PAGES/keys/$LINE/qmdmm-packages-before.gpg" "$W/keys/before.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg"        "$W/keys/after.gpg"

root_before=$(key_fpr "$W/keys/before.gpg"); root_after=$(key_fpr "$W/keys/after.gpg")
sub_before=$(live_sub_fpr "$W/keys/before.gpg")
sub_after=$(live_sub_fpr "$W/keys/after.gpg")
dead_after=$(dead_subkeys "$W/keys/after.gpg")
revoked_in_after=$(dead_sub_fpr "$W/keys/after.gpg")

echo "  before: root $root_before, live subkey $sub_before (the outgoing one)"
echo "  after:  root $root_after, live subkey $sub_after (the incoming one)"

[ "$root_before" = "$root_after" ] \
  || { echo "  !! the two files do not share a root key"; exit 1; }
[ "$(dead_subkeys "$W/keys/before.gpg")" = 0 ] \
  || { echo "  !! the 'before' file is not the un-refreshed state"; exit 1; }
[ "$dead_after" = 1 ] && [ "$revoked_in_after" = "$sub_before" ] \
  || { echo "  !! the 'after' file does not revoke the outgoing subkey"; exit 1; }
[ "$sub_before" != "$sub_after" ] \
  || { echo "  !! the live subkey did not change, so no rotation happened"; exit 1; }
echo "  OK: one root key, the outgoing subkey revoked, the incoming one live"

# What the keyring thinks of a subkey, read straight out of the keyring pacman
# actually uses. Needed because "the database was refused" has two possible
# causes here - the revocation arrived, or the key went missing - and only one
# of them is the measurement.
kr_state() {  # kr_state <subkey-fpr>
  gpg --homedir "$KR" --with-colons --list-keys "$1" 2>/dev/null \
    | awk -F: -v want="$1" '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f && $10==want){print s; exit}}'
}

set_server() {  # set_server <baseurl>
  cp "$W/pacman.conf.orig" "$CONF"
  cat >> "$CONF" <<EOF

[$REPO]
SigLevel = Required DatabaseRequired
Server = $1
EOF
  echo "  | [$REPO]  Server = $1"
}

lsign() {  # lsign <subkey-fpr>
  if pacman-key --lsign-key "$1" >"$W/lsign.log" 2>&1; then
    echo "  locally signed $1"
  else
    echo "  !! pacman-key refused to locally sign $1:"
    sed 's/^/    /' "$W/lsign.log"; return 1
  fi
}

# read_one <label> <baseurl> <tag> -> echoes accepted|refused
read_one() {
  local label="$1" base="$2" tag="$3" seen
  echo
  echo "--- $label ---"
  set_server "$base"
  rm -rf /var/lib/pacman/sync/*
  # The exit status is not the verdict: `pacman -Sy` refreshes every configured
  # repository, so a failure on this one is indistinguishable from a failure on
  # the distribution's own. Ask what pacman can see in THIS repository.
  pacman -Sy --noconfirm > "$W/$tag.log" 2>&1 || true
  echo "  --- what pacman said ---" >&2
  grep -iE 'revok|invalid|corrupted|unknown key|signature|error|warning' "$W/$tag.log" \
    | head -8 | sed 's/^/    /' >&2 || true
  seen=$(pacman -Sl "$REPO" 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ' || true)
  if [ -n "$seen" ]; then
    echo "  pacman lists: $seen" >&2
    echo "  VERDICT: accepted" >&2
    printf 'accepted'
  else
    echo "  VERDICT: refused (the repository is invisible to pacman)" >&2
    printf 'refused'
  fi
}

fail() { echo "  !! $1"; exit 1; }

echo
echo "=== phase A: the keyring a consumer has BEFORE it refreshes ==="
pacman-key --add "$W/keys/before.gpg" 2>&1 | sed 's/^/    /'
lsign "$sub_before" || fail "the un-refreshed keyring cannot be built, nothing below would mean anything"
[ "$(kr_state "$sub_before")" = u ] \
  || fail "the keyring does not consider the outgoing subkey usable after signing it"
echo "  keyring state of the outgoing subkey: $(kr_state "$sub_before") (usable)"

v=$(read_one "1) frozen source, keyring NOT refreshed  -> must be accepted" \
             "$PAGES/$LINE-revoked" p1)
[ "$v" = accepted ] || fail "the control was refused, so nothing below would mean anything"

v=$(read_one "2) rebuilt source, keyring NOT refreshed  -> must be refused" \
             "$PAGES/$LINE/$VERSION" p2)
[ "$v" = refused ] || fail "a consumer that has not refreshed its keyring can read the new source"

echo
echo "=== phase B: the same consumer, after refreshing its key material ==="
pacman-key --add "$W/keys/after.gpg" 2>&1 | sed 's/^/    /'
lsign "$sub_after" || fail "the incoming subkey cannot be locally signed, so service is not restored"
# The load-bearing check for corner 3. If the revocation certificate had not
# actually reached the keyring, corner 3 would be refused for a different
# reason - or, worse, accepted and read as a finding about pacman.
echo "  keyring state of the outgoing subkey after the refresh: $(kr_state "$sub_before") (want r)"
[ "$(kr_state "$sub_before")" = r ] \
  || fail "the refresh did not bring the revocation certificate into the keyring"

v=$(read_one "3) frozen source, keyring refreshed      -> the measurement" \
             "$PAGES/$LINE-revoked" p3)
if [ "$v" = refused ]; then
  echo "  -> pacman refuses the outgoing subkey's output once it holds the"
  echo "     certificate, which is FINDINGS 10.7 re-measured on a real rotation"
elif [ "$v" = accepted ]; then
  echo "  !! pacman ACCEPTED it - it no longer enforces revocation, so FINDINGS"
  echo "     10.7 is out of date and this cell should be flipped."
  fail "the verdict changed from the recorded one (refused)"
else
  fail "unreadable verdict: $v"
fi

v=$(read_one "4) rebuilt source, keyring refreshed     -> must be accepted" \
             "$PAGES/$LINE/$VERSION" p4)
[ "$v" = accepted ] || fail "the rotation left the line broken for a refreshed consumer"

echo
echo "=== B/rotated (pacman, $LINE): PASS ==="
