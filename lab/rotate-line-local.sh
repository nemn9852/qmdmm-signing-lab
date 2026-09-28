#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI. Rotates ONE line's signing subkey
# while leaving the root key - the trust anchor - exactly where it is.
#
#   rotate-line-local.sh <line>          one of the seven lines in lab/lines.tsv
#
# What it does, in order, and only the first two of these can be got wrong in a
# way that cannot be undone:
#
#   0. assert the outgoing subkey is still usable - rotating from an already-dead
#      subkey would quietly produce a key file with two revoked subkeys in it
#   1. freeze the two things a consumer can be handed, BEFORE anything changes:
#        keys/<line>/qmdmm-packages-before.gpg
#            the trust material a consumer has if it has NOT refreshed - i.e.
#            root + outgoing, with no revocation certificate in it yet. This has
#            to be exported before step 2: exporting after the revocation gives
#            a file that already carries the certificate, which is the other
#            cell of the 2x2 and therefore useless as the "before" one.
#        site/<line>-revoked/
#            the source this line publishes right now, as a consumer reads it
#            (metadata only). For rpm and pacman this is FETCHED from Pages, so
#            it must happen BEFORE the next publish rebuilds the row with the
#            incoming subkey; a copy taken after that is not the old source at
#            all. For the deb lines it is built here instead, with the outgoing
#            subkey, because building it needs no tooling the trusted machine
#            lacks.
#   2. revoke the outgoing subkey
#   3. add a fresh signing subkey
#   4. re-sign what only the root key may sign - the deb lines' keyring source.
#      The rpm and pacman lines have no such artifact yet (FINDINGS 10.8: the
#      *-release / keyring packages are a mechanism that does not exist in this
#      lab), so for them this step is ABSENT and says so, rather than being
#      skipped in silence.
#   5. re-export the line's public key file: root + outgoing[revoked] + incoming.
#      Carrying the revoked subkey is deliberate - it is what lets a consumer
#      that HAS refreshed report "revoked" rather than "unknown key".
#   6. write the incoming subkey's secret for the CI environment.
#
# NOT part of this script, and the rotation is not finished without it:
#
#   upload the secret (the command is printed at the end), then re-run the
#   workflow. Until both happen the line has no usable private half in CI and
#   stage S fails - which is the honest state, not a bug.
#
# What does NOT happen: the root key is not touched, no other line's subkey is
# touched, and nothing here needs CI credentials beyond the one secret upload.
#
# TRUSTED-MACHINE TOOL, not a CI step (hence the -local suffix). It sources the
# local keyring env on purpose: rotation needs the root key to revoke and to
# sign the keyring source, and the root secret never enters CI.
set -euo pipefail

DISTRO="${1:?usage: rotate-line-local.sh <line>   (see lab/lines.tsv)}"
cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME, ROOT, SUB_*, LAB_REPO, LAB_PAGES

# Which format this line speaks decides three of the six steps. The debian and
# pacman lines have no per-version distinction in this part of the scheme; the
# rpm ones do not either. What differs is which artifact carries the trust root.
case "$DISTRO" in
  debian|ubuntu)     FMT=deb ;;
  fedora|rocky|alma) FMT=rpm ;;
  arch|manjaro)      FMT=pac ;;
  *) echo "!! unknown line: $DISTRO   (lab/lines.tsv lists them)"; exit 1 ;;
esac

_v="SUB_${DISTRO^^}"
OLD_SUB="${!_v:?env.sh has no $_v}"
PKGFILE="keys/$DISTRO/qmdmm-packages.gpg"
BEFOREFILE="keys/$DISTRO/qmdmm-packages-before.gpg"
FIXTURE="site/$DISTRO-revoked"
OLDKEYID="${OLD_SUB: -16}"

# The version the frozen source is taken from: the first row this line has.
VERSION=$(awk -F'\t' -v l="$DISTRO" '$1==l {print $4; exit}' lab/lines.tsv)
[ -n "$VERSION" ] || { echo "!! $DISTRO has no row in lab/lines.tsv"; exit 1; }

echo "=== scope ==="
echo "  line            = $DISTRO ($FMT, freezing $VERSION)"
echo "  root            = $ROOT   (untouched)"
echo "  outgoing subkey = $OLD_SUB"

# ------------------------------------------------------------------ step 0
echo
echo "=== 0) the outgoing subkey must still be usable ==="
nowlive=$(gpg --with-colons --list-keys "$ROOT" 2>/dev/null \
          | awk -F: '/^sub:/{s=$2} /^fpr:/{if (s && $10=="'"$OLD_SUB"'") {print (s ~ /^[redi]$/ ? "dead" : "live"); exit}}')
case "$nowlive" in
  live) echo "  OK: $OLDKEYID is live" ;;
  dead) echo "  !! $OLDKEYID is already revoked - rotating from it would leave this"
        echo "     line's key file carrying two revoked subkeys and no live one"; exit 1 ;;
  *)    echo "  !! $OLD_SUB is not on $ROOT at all"; exit 1 ;;
esac

# ------------------------------------------------------------------ step 1a
echo
echo "=== 1a) freeze the trust material a consumer has NOT refreshed ==="
echo "  (must be exported BEFORE the revocation, or it carries the certificate)"
gpg --batch --armor --export "${OLD_SUB}!" > "$BEFOREFILE.asc"
gpg --dearmor < "$BEFOREFILE.asc" > "$BEFOREFILE"
rm -f "$BEFOREFILE.asc"
before_live=$(gpg --with-colons --show-keys "$BEFOREFILE" 2>/dev/null \
              | awk -F: '/^sub:/{if ($2 !~ /^[redi]$/) n++} END{print n+0}')
before_dead=$(gpg --with-colons --show-keys "$BEFOREFILE" 2>/dev/null \
              | awk -F: '/^sub:/{if ($2 ~ /^[redi]$/) n++} END{print n+0}')
echo "  $BEFOREFILE: $before_live live, $before_dead revoked"
[ "$before_live" = 1 ] && [ "$before_dead" = 0 ] \
  || { echo "  !! the 'before' state is not root + one live subkey"; exit 1; }

# ------------------------------------------------------------------ step 1b
echo
echo "=== 1b) freeze the source this line publishes right now ==="
rm -rf "$FIXTURE"
case "$FMT" in
  deb)
    # Built rather than fetched: the outgoing subkey has to sign it, and doing
    # that needs nothing the trusted machine does not already have. (The other
    # two formats are fetched, because building them needs createrepo_c /
    # repo-add, which live in their distribution's containers and not here.)
    bash lab/mkrepo-debian.sh "$OLD_SUB" "$FIXTURE" "$VERSION" \
         "frozen snapshot signed by the subkey that is revoked next"
    ;;
  rpm|pac)
    # shellcheck source=lab/lib-site.sh
    . lab/lib-site.sh
    fetch_row_metadata "$LAB_PAGES/$DISTRO/$VERSION" "$FMT" "$FIXTURE" \
      || { echo "  !! could not freeze $DISTRO/$VERSION from Pages"; exit 1; }
    ;;
esac

# ------------------------------------------------------------------ step 2
echo
echo "=== 2) revoke the outgoing subkey ==="
printf 'key %s\nrevkey\ny\n0\n\ny\nsave\n' "$OLDKEYID" | \
  gpg --batch --command-fd 0 --status-fd 2 --edit-key "$ROOT" > /dev/null 2>&1
echo "  subkey revocation flags now:"
gpg --with-colons --list-keys "$ROOT" 2>/dev/null \
  | awk -F: '/^sub:/{printf "    sub rev=%s keyid=%s\n", $2, $5}'

# ------------------------------------------------------------------ step 3
echo
echo "=== 3) add a fresh signing subkey ==="
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$ROOT" ed25519 sign 0 2>&1 | tail -2 || true
NEW_SUB=$(gpg --with-colons --list-secret-keys "$ROOT" 2>/dev/null \
            | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
if [ -z "$NEW_SUB" ] || [ "$NEW_SUB" = "$OLD_SUB" ]; then
  echo "  !! could not determine the new subkey"; exit 1
fi
echo "  new subkey = $NEW_SUB"

# ------------------------------------------------------------------ step 4
echo
echo "=== 4) re-sign what only the root key may sign ==="
case "$FMT" in
  deb)
    bash lab/mkrepo-debian.sh "$ROOT" "site/$DISTRO-keyring" "$VERSION" \
         "keyring source (root-signed)"
    ;;
  rpm|pac)
    echo "  ABSENT for this format, not skipped: this lab has no keyring/$FMT-release"
    echo "  artifact for the root key to sign (FINDINGS 10.8). The rpm and pacman"
    echo "  lines therefore take their trust root from the published key FILE, and"
    echo "  step 5 below is the whole of their trust-material update."
    ;;
esac

# ------------------------------------------------------------------ step 5
echo
echo "=== 5) re-export this line's public key file ==="
echo "  (root + outgoing[revoked] + incoming)"
gpg --batch --armor --export "${OLD_SUB}!" "${NEW_SUB}!" > "$LAB/pub-$DISTRO.asc"
gpg --dearmor < "$LAB/pub-$DISTRO.asc" > "$PKGFILE"
python3 "$LAB/pktstat.py" "$LAB/pub-$DISTRO.asc" | sed 's/^/    /'
after_live=$(gpg --with-colons --show-keys "$PKGFILE" 2>/dev/null \
             | awk -F: '/^sub:/{if ($2 !~ /^[redi]$/) n++} END{print n+0}')
after_dead=$(gpg --with-colons --show-keys "$PKGFILE" 2>/dev/null \
             | awk -F: '/^sub:/{if ($2 ~ /^[redi]$/) n++} END{print n+0}')
gotlive=$(gpg --with-colons --show-keys "$PKGFILE" 2>/dev/null \
          | awk -F: '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f && s !~ /^[redi]$/){print $10; exit}}')
echo "  $PKGFILE: $after_live live, $after_dead revoked; the live one is $gotlive"
[ "$after_live" = 1 ] && [ "$after_dead" = 1 ] && [ "$gotlive" = "$NEW_SUB" ] \
  || { echo "  !! the key file is not root + outgoing[revoked] + incoming"; exit 1; }

# ------------------------------------------------------------------ step 6
echo
echo "=== 6) write the incoming subkey's secret for the CI environment ==="
# umask first: this file is a private key and must not exist world-readable even
# for an instant. The `--pinentry-mode loopback` is not needed here, but the
# file's mode is the point.
umask 077
gpg --batch --armor --export-secret-subkeys "${NEW_SUB}!" > "$LAB/priv-$DISTRO.asc"
chmod 600 "$LAB/priv-$DISTRO.asc"
openssl base64 -A -in "$LAB/priv-$DISTRO.asc" -out "$LAB/priv-$DISTRO.b64"
chmod 600 "$LAB/priv-$DISTRO.b64"
echo "  wrote $LAB/priv-$DISTRO.b64 ($(wc -c < "$LAB/priv-$DISTRO.b64" | tr -d ' ') bytes, mode $(stat -f '%Lp' "$LAB/priv-$DISTRO.b64" 2>/dev/null || echo '?'))"

# keep env.sh pointing at the live subkey so the next run rotates the right one
sed -i '' "s|^export SUB_${DISTRO^^}=.*|export SUB_${DISTRO^^}=$NEW_SUB|" "$LAB/env.sh"
echo "  env.sh: SUB_${DISTRO^^} -> $NEW_SUB"

echo
echo "=== the rotation is NOT finished until the secret is uploaded ==="
echo "  gh secret set SIGNING_KEY --repo $LAB_REPO --env $DISTRO < $LAB/priv-$DISTRO.b64"
echo "  then delete $LAB/priv-$DISTRO.asc and $LAB/priv-$DISTRO.b64, and re-run the workflow."
echo
echo "NEW_SUB=$NEW_SUB"
