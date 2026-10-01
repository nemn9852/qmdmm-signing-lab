#!/usr/bin/env bash
#
# The Alpine line's RELEASE key, generated the way abuild expects to find it.
#
# Alpine is the one line that is not GPG. abuild-keygen / abuild-sign are plain
# shell around OpenSSL, and apk resolves a package's signature by looking for a
# file whose *name* is the signature member - ".SIGN.RSA.<basename>" - inside
# /etc/apk/keys. So this key has no subkeys, no root/operational split and no
# revocation of any kind: the file name *is* the identity, and rotating means
# generating a new name and asking every consumer to drop the old file by hand.
# That is why the name is chosen here and why this runs before the first release
# rather than after one.
#
# THIS LINE HOLDS TWO KEYS, and the naming is what tells them apart:
#
#   qmdmm-daily-<hex>    what ci/pack-apk.sh signs with every day. abuild calls
#                        abuild-sign unconditionally - signing cannot be switched
#                        off - so the daily build has to hold *some* key, and
#                        this is the one it holds. Its output never leaves the
#                        workflow: smoke packages travel as artifacts to stages
#                        B and C and are not published, so no consumer ever needs
#                        its public half and rotating it costs nobody anything.
#                        This was the first key the line had, as
#                        qmdmm-release-6abe0b34, and was renamed on 2026-10-01
#                        when a second key arrived and the roles needed names.
#                        The hex is deliberately the same one: the pair of names
#                        should read as one key relabelled, not as a rotation
#                        that never happened.
#
#   qmdmm-release-<hex>  what THIS script makes: the only key a consumer of a
#                        published Alpine repository should trust. Its private
#                        half goes to the `alpine` environment's SIGNING_KEY,
#                        which the daily workflow does not declare and therefore
#                        cannot reach. That environment boundary - not a promise
#                        - is what keeps day-to-day signing off the release key.
#
# The name is "qmdmm-release-<hex>", the hex being a unix timestamp - the shape
# abuild-keygen itself produces ("${emailaddr:-$USER}-<hex>"), i.e. a fresh name
# per rotation with nothing platform-specific in it. (The daily key's hex is the
# one exception, for the reason above.) The name before both of these was
# neve-6aaaace6, which abuild-keygen had defaulted from the machine's user during
# a local run on 2026-09-16; a name that ends up in every package's signature
# member and in every consumer's /etc/apk/keys is not a place for one.
#
# Two things this deliberately does NOT do, both the same decisions as
# lab/genesis-production.sh:
#
#   * it does not upload anything. The secret is set by a command it prints and
#     the public half is committed by hand, so that what went to GitHub is
#     something a person chose to send;
#   * it does not keep a second copy anywhere. One private key file, on this
#     machine, 0600. Losing it means generating a new name and telling every
#     consumer to replace the file in /etc/apk/keys - the same repair a
#     compromise would need, which is the cost of a line with no revocation.
#
# It refuses to run over an existing key of the same name. It cannot tell whether
# a release key already exists under a *different* name - only the `alpine`
# environment knows that - so the guard is on the files it is about to write, and
# the printed instructions say what to compare against GitHub.
set -euo pipefail

PROD="${PROD:-$HOME/qmdmm-signing-prod}"
NAME="${NAME:-qmdmm-release-$(printf '%x' "$(date +%s)")}"

KEYDIR="$PROD/alpine"          # private half, 0700
OUTDIR="$PROD/out/alpine"      # public half, alongside the other published material
KEY="$KEYDIR/$NAME.rsa"
PUB="$OUTDIR/$NAME.rsa.pub"

for f in "$KEY" "$PUB"; do
  if [ -e "$f" ]; then
    echo "!! refusing to run: $f already exists" >&2
    exit 1
  fi
done

umask 077
mkdir -p "$KEYDIR" "$OUTDIR"
chmod 700 "$KEYDIR"
# out/ is where the material meant to be published lives, and it is world-
# readable; a 0700 subdirectory of it would be readable in name only.
chmod 755 "$OUTDIR"

# PKCS#8, which is what OpenSSL 3 writes by default, and not `-traditional`:
# abuild runs on this same OpenSSL generation and reads the file with
# `openssl pkey`-style calls, which want the modern container. (The private half
# is a bare RSA key, so this choice is about the container and not the key.)
openssl genrsa -out "$KEY" 4096
openssl pkey -in "$KEY" -pubout -out "$PUB"

# Both halves, asserted in both directions. A private key that is world-readable
# is worthless, and a public key only its owner can read is worthless in a
# different way - the first production genesis got this wrong once, in the
# direction that looks harmless, so neither side is assumed from the umask.
chmod 600 "$KEY"
chmod 644 "$PUB"

perm_ok=1
for pair in "$KEY:600" "$PUB:644"; do
  f=${pair%:*}; want=${pair#*:}
  got=$(stat -f '%Lp' "$f")
  if [ "$got" != "$want" ]; then
    echo "!! $f is $got, expected $want" >&2
    perm_ok=0
  fi
done
[ "$perm_ok" = 1 ] || exit 1

# Intact, and the size that was asked for. Read off the private half without
# printing any of it: `-check` prints only its verdict, and a damaged key is
# caught by the exit code rather than by matching a string.
openssl pkey -in "$KEY" -noout -check
bits=$(openssl pkey -pubin -in "$PUB" -noout -text | sed -n 's/^Public-Key: (\([0-9]*\) bit).*/\1/p')
echo "the key is $bits bits"

# The two halves are one pair. This is the assertion ci/pack-apk.sh makes before
# it builds anything - and there it fails only after a full build, which is what
# makes paying for it here worth the two seconds.
openssl pkey -in "$KEY" -pubout -outform DER \
  | cmp - <(openssl pkey -pubin -in "$PUB" -outform DER)
echo "the two halves are the same pair"

# A worked signature, with a negative control beside it. A check that cannot
# fail proves nothing, and "Verified OK" would read the same if the private half
# were not the one doing the signing.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'qmdmm alpine packager key\n' > "$tmp/msg"
openssl dgst -sha256 -sign "$KEY" -out "$tmp/sig" "$tmp/msg"
openssl dgst -sha256 -verify "$PUB" -signature "$tmp/sig" "$tmp/msg"
printf 'tampered\n' >> "$tmp/msg"
if openssl dgst -sha256 -verify "$PUB" -signature "$tmp/sig" "$tmp/msg" >/dev/null 2>&1; then
  echo "!! the negative control verified - the check above proves nothing" >&2
  exit 1
fi
echo "negative control: a tampered message does not verify"

fp=$(openssl pkey -pubin -in "$PUB" -outform DER | openssl dgst -sha256 | sed 's/^.*= //')

cat <<EOF

private key   $KEY   (0600, this machine only, no copy anywhere)
public key    $PUB
sha256(DER)   $fp

One value in three places, and they have to agree or a published package is
uninstallable: the committed file name, the file name inside the secret, and
PACKAGER_KEY in the workflow that uses it.

Alpine holds two keys and they are not interchangeable. The daily one
(qmdmm-daily-*) signs every day's build and is not touched here: nothing it
signs is published, so no consumer is ever told to trust it. This key is the
release half, and the only one a consumer of a published repository should end
up with in /etc/apk/keys.

  1. commit the public half next to the daily key's:

       QMdmm/QMdmmPackagingCi:packaging/alpine/$NAME.rsa.pub

     Nothing else in packaging/alpine/ changes and the daily key keeps its
     name. The two are told apart by role in packaging/alpine/NOTES.md.

  2. put the private half in the line's environment, under the same secret name
     the other seven lines use, so that every line's key is read out of
     secrets.SIGNING_KEY and the environment the job declares is what picks the
     line:

       gh api -X PUT repos/QMdmm/QMdmmPackagingCi/environments/alpine
       gh secret set SIGNING_KEY -R QMdmm/QMdmmPackagingCi --env alpine < "$KEY"

     Not the repository-level secret: that one holds the DAILY key
     (PACKAGER_PRIVKEY), every workflow in the repository can read it, and the
     daily workflow is precisely the one that must not be able to sign a
     release.

  3. set PACKAGER_KEY to exactly the name above, in the workflow that publishes
     (release.yml - not written yet; the daily workflow keeps
     qmdmm-daily-6abe0b34 and is not edited).

EOF
