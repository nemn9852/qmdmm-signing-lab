#!/bin/bash
#
# Genesis for the PRODUCTION trust root: one root key, one sign-only subkey per
# release line, and the two public files each line's keyring package installs.
#
# TRUSTED-MACHINE TOOL, not a CI step (same shape as rotate-line-local.sh). It
# creates the root secret, so it must only ever run on the machine that owns it.
# The root secret never enters CI: what leaves this machine is, per line, the
# subkey's secret (for that line's Environment) and public material.
#
# Design decisions this implements (subkey-granularity-design §4.4, §7):
#   - one key per distro LINE, not per version  => 7 lines, apk excluded
#   - keyring packages are signed by the ROOT, so no extra root subkey exists
#   - each line's keyring package installs TWO files:
#       qmdmm-root.gpg      root only          -> the keyring source's Signed-By
#       qmdmm-packages.gpg  root + that line's P_i -> the everyday source
#     Only the first file keeps a leaked P_i from replacing the trust root.
#
# WHAT IT DOES NOT DO (deliberately, so the irreversible parts stay manual):
#   - it does not create GitHub Environments, set secrets, or push anything;
#     it prints the exact commands, because those leave traces that outlive a
#     mistake in this script
#   - it does not back the root secret up. Whether the root has an offline copy
#     is a decision, not a default; see the note it prints at the end.
#
# env:
#   PROD_UID        "<name> <email>" for the root key   (required)
#   PROD_ALGO       ed25519 | rsa4096                   (default ed25519)
#   PROD_GNUPGHOME  keyring for the root                (default ~/qmdmm-signing-prod/gnupg)
#   PROD_OUT        where the artifacts are written      (default ~/qmdmm-signing-prod/out)
#   PROD_LINES      space-separated lines                (default: the GPG lines in lab/lines.tsv)
#
set -euo pipefail
cd "$(dirname "$0")/.."                                   # -> repo/

PROD_UID="${PROD_UID:?usage: PROD_UID='<name> <email>' genesis-production.sh}"
PROD_ALGO="${PROD_ALGO:-ed25519}"
PROD_GNUPGHOME="${PROD_GNUPGHOME:-$HOME/qmdmm-signing-prod/gnupg}"
PROD_OUT="${PROD_OUT:-$HOME/qmdmm-signing-prod/out}"

# Both are used in `rm -rf` further down (a scratch keyring per line), so neither
# may be empty or a filesystem root. The default is outside the repo on purpose:
# the secret material must not be one `git add -A` away from being committed.
case "$PROD_GNUPGHOME" in ""|/) echo "!! refusing: PROD_GNUPGHOME is empty or /"; exit 1 ;; esac
case "$PROD_OUT" in ""|/) echo "!! refusing: PROD_OUT is empty or /"; exit 1 ;; esac

case "$PROD_ALGO" in
  ed25519|rsa4096) ;;
  *) echo "!! unsupported PROD_ALGO: $PROD_ALGO (ed25519 | rsa4096)"; exit 1 ;;
esac

# 7 lines, derived rather than listed: a hard-coded list here would go stale the
# day a line is added to lab/lines.tsv, and silently generate 6 keys instead of 7.
PROD_LINES="${PROD_LINES:-$(awk -F'\t' 'NR>1 && $2!="apk"{print $1}' lab/lines.tsv | sort -u | tr '\n' ' ')}"
[ -n "$PROD_LINES" ] || { echo "!! no lines: lab/lines.tsv gave none"; exit 1; }

# --- the guards. Each one protects against a specific way to lose a trust root.
[ ! -e "$PROD_GNUPGHOME" ] \
  || { echo "!! $PROD_GNUPGHOME already exists. Genesis must start from nothing:"
       echo "   generating into a populated keyring makes two roots, and then it is"
       echo "   not clear which one signed anything. Move it aside and retry."; exit 1; }
case "$PROD_GNUPGHOME" in
  "$HOME/.gnupg"*|"$HOME/qmdmm-signing-lab"*)
    echo "!! refusing: PROD_GNUPGHOME must not be the identity keyring or the lab's"
    exit 1 ;;
esac

export GNUPGHOME="$PROD_GNUPGHOME"
umask 077                       # the secret files must never exist world-readable
mkdir -p "$GNUPGHOME" "$PROD_OUT"
chmod 700 "$GNUPGHOME"
chmod 755 "$PROD_OUT"           # public material lives here; secrets go 600 below

gpgconf --kill gpg-agent 2>/dev/null || true

echo "=== production genesis ==="
echo "  uid        $PROD_UID"
echo "  algo       $PROD_ALGO"
echo "  keyring    $GNUPGHOME"
echo "  out        $PROD_OUT"
echo "  lines      $PROD_LINES"
echo
echo "--- 1) the root key (cert+sign; it signs the keyring packages) ---"
# No passphrase: §7bis measured that a passphrase on the root propagates to every
# subkey and therefore has to be handed to CI as well, where it would also unlock
# the root. The root's protection is that this key never leaves this machine.
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$PROD_UID" "$PROD_ALGO" cert,sign 0 2>&1 | tail -2
ROOT=$(gpg --with-colons --list-keys "$PROD_UID" | awk -F: '/^fpr:/{print $10; exit}')
ROOT_CAP=$(gpg --with-colons --list-keys "$ROOT" | awk -F: '/^pub:/{print $12}')
echo "  root fpr   $ROOT"
echo "  root caps  $ROOT_CAP"
case "$ROOT_CAP" in *[Cc]*) ;; *) echo "!! root cannot certify: subkeys could not be added"; exit 1 ;; esac

# The one thing users are told to check. Written first so it exists even if a
# later line fails, and so the value is never copied out of a terminal by hand.
ROOT_PUB="$PROD_OUT/qmdmm-root.gpg"
gpg --batch --armor --export "$ROOT!" > "$PROD_OUT/qmdmm-root.asc"
gpg --dearmor < "$PROD_OUT/qmdmm-root.asc" > "$ROOT_PUB"
rm -f "$PROD_OUT/qmdmm-root.asc"

echo
echo "--- 2) one sign-only subkey per line ---"
: > "$PROD_OUT/lines.tsv"
for L in $PROD_LINES; do
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-add-key "$ROOT" "$PROD_ALGO" sign 0 2>&1 | tail -1
  SUB=$(gpg --with-colons --list-secret-keys "$ROOT" \
        | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
  [ -n "$SUB" ] || { echo "  !! $L: no subkey was created"; exit 1; }
  printf '%s\t%s\n' "$L" "$SUB" >> "$PROD_OUT/lines.tsv"
  echo "  $L  ->  $SUB"
done

echo
echo "--- 3) public material per line ---"
# qmdmm-root.gpg is shared (one file), qmdmm-packages.gpg is per line.
for L in $PROD_LINES; do
  SUB=$(awk -F'\t' -v l="$L" '$1==l{print $2}' "$PROD_OUT/lines.tsv")
  mkdir -p "$PROD_OUT/$L"
  gpg --batch --armor --export "$ROOT!" "${SUB}!" > "$PROD_OUT/$L/qmdmm-packages.asc"
  gpg --dearmor < "$PROD_OUT/$L/qmdmm-packages.asc" > "$PROD_OUT/$L/qmdmm-packages.gpg"
  rm -f "$PROD_OUT/$L/qmdmm-packages.asc"
  cat "$ROOT_PUB" > "$PROD_OUT/$L/qmdmm-root.gpg"     # the package installs both
  live=$(gpg --with-colons --show-keys "$PROD_OUT/$L/qmdmm-packages.gpg" \
         | awk -F: '/^sub:/{if ($2 !~ /^[redi]$/) n++} END{print n+0}')
  got=$(gpg --with-colons --show-keys "$PROD_OUT/$L/qmdmm-packages.gpg" \
        | awk -F: '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f && s !~ /^[redi]$/){print $10; exit}}')
  # both halves matter: the count catches a stray extra subkey, the fingerprint
  # catches "one subkey, but the wrong line's".
  [ "$live" = 1 ] && [ "$got" = "$SUB" ] \
    || { echo "  !! $L: qmdmm-packages.gpg has $live live subkeys, live one is $got"; exit 1; }
  roots_only=$(gpg --with-colons --show-keys "$PROD_OUT/$L/qmdmm-root.gpg" \
               | awk -F: '/^sub:/{n++} END{print n+0}')
  [ "$roots_only" = 0 ] \
    || { echo "  !! $L: qmdmm-root.gpg carries $roots_only subkey(s); it must be root only"; exit 1; }
  echo "  $L  root-only $(wc -c < "$PROD_OUT/$L/qmdmm-root.gpg" | tr -d ' ') B, root+P_i $(wc -c < "$PROD_OUT/$L/qmdmm-packages.gpg" | tr -d ' ') B"
done

echo
echo "--- 4) one secret per line, for that line's Environment ---"
# 600 from the start (umask above) and verified below: this is the file that
# becomes a GitHub secret, and it is the only private material genesis emits.
for L in $PROD_LINES; do
  SUB=$(awk -F'\t' -v l="$L" '$1==l{print $2}' "$PROD_OUT/lines.tsv")
  gpg --batch --armor --export-secret-subkeys "${SUB}!" > "$PROD_OUT/$L/secret.asc"
  chmod 600 "$PROD_OUT/$L/secret.asc"
  openssl base64 -A -in "$PROD_OUT/$L/secret.asc" -out "$PROD_OUT/$L/secret.b64"
  chmod 600 "$PROD_OUT/$L/secret.b64"
  # Structural assertions only - never by printing the material:
  #   sec=1 ssb=1  : the primary is a dummy shell, exactly one subkey's secret
  #   the subkey in the file is the one this line is supposed to use
  read -r nsec nssb <<<"$(gpg --with-colons --show-keys "$PROD_OUT/$L/secret.asc" \
       | awk -F: '/^sec:/{s++} /^ssb:/{b++} END{printf "%d %d", s+0, b+0}')"
  got_sub=$(gpg --with-colons --show-keys "$PROD_OUT/$L/secret.asc" \
            | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
  [ "$nsec" = 1 ] && [ "$nssb" = 1 ] \
    || { echo "  !! $L: secret.asc has sec=$nsec ssb=$nssb (want 1 1)"; exit 1; }
  [ "$got_sub" = "$SUB" ] \
    || { echo "  !! $L: secret.asc holds $got_sub, not this line's $SUB"; exit 1; }
  echo "  $L  secret.asc $(wc -c < "$PROD_OUT/$L/secret.asc" | tr -d ' ') B mode $(stat -f '%Lp' "$PROD_OUT/$L/secret.asc")"
done

echo
echo "--- 5) what each line's secret actually confers ---"
# Three assertions per line, made here rather than in CI because this is where
# the material is created. Equal sizes across lines prove nothing (all seven
# secret.asc files came out the same size), so the content is what gets checked:
#   1. importing it yields exactly ONE private key (a dummy primary makes none)
#   2. the ROOT cannot sign in that keyring - if it can, the export carried the
#      root's secret and every line's Environment has the trust root in it
#   3. the line's own subkey can sign, with no passphrase
# and separately, that no two lines were handed byte-identical files.
seen=""
for L in $PROD_LINES; do
  SUB=$(awk -F'\t' -v l="$L" '$1==l{print $2}' "$PROD_OUT/lines.tsv")
  V="$PROD_OUT/.verify-$L"
  rm -rf "$V"; mkdir -p "$V"; chmod 700 "$V"
  GNUPGHOME="$V" gpg --batch --quiet --import "$PROD_OUT/$L/secret.asc" 2>/dev/null
  nfiles=$(find "$V/private-keys-v1.d" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$nfiles" = 1 ] \
    || { echo "  !! $L: import produced $nfiles private key files (want exactly 1)"; exit 1; }
  printf 'probe' > "$V/m"
  # The root's PUBLIC half must be in this keyring, or "it cannot sign" would be
  # true for the trivial reason that gpg never found the key - a vacuous pass
  # that a wrong fingerprint would produce. Measured: a full secret export into
  # an empty keyring gives 8 private files and the root CAN sign, so both halves
  # of this assertion are known to be able to fail.
  GNUPGHOME="$V" gpg --batch --list-keys "$ROOT" >/dev/null 2>&1 \
    || { echo "  !! $L: root public key absent from the imported keyring"; exit 1; }
  if GNUPGHOME="$V" gpg --batch --pinentry-mode loopback --passphrase '' \
       -u "${ROOT}!" --detach-sign -o /dev/null "$V/m" 2>"$V/root.err"; then
    echo "  !! $L: the ROOT signs in this keyring - secret.asc carries the root secret"; exit 1
  fi
  # Same-object discipline: a failure for any reason would look the same. The
  # reason here has to be "the secret is not there", not "no such key".
  grep -qi 'secret key\|No secret' "$V/root.err" \
    || { echo "  !! $L: the root failed to sign, but not because it has no secret here:"; sed 's/^/     /' "$V/root.err"; exit 1; }
  GNUPGHOME="$V" gpg --batch --pinentry-mode loopback --passphrase '' \
    -u "$SUB" --detach-sign -o "$V/s" "$V/m" 2>/dev/null \
    || { echo "  !! $L: this line's own subkey cannot sign"; exit 1; }
  sum=$(shasum -a 256 < "$PROD_OUT/$L/secret.asc" | cut -c1-16)
  case " $seen " in
    *" $sum "*) echo "  !! $L: its secret is byte-identical to another line's"; exit 1 ;;
  esac
  seen="$seen $sum"
  rm -rf "$V"                       # the scratch keyring holds a secret; never leave it
  echo "  $L  1 private key, root refused, subkey signed   sha256 ${sum}…"
done

echo
echo "--- 6) the fingerprint list users will be told to compare ---"
# Same shape as keys/fingerprints.txt in this repo, and grouped the same way, so
# the two can be diffed by eye when the lab is eventually retired.
{
  printf '  %-8s%s  %s\n' "root" "$(printf '%s' "${ROOT:0:20}" | sed -E 's/(....)/\1 /g; s/ $//')" "$(printf '%s' "${ROOT:20}" | sed -E 's/(....)/\1 /g; s/ $//')"
  while IFS=$'\t' read -r L SUB; do
    printf '  %-8s%s  %s\n' "$L" "$(printf '%s' "${SUB:0:20}" | sed -E 's/(....)/\1 /g; s/ $//')" "$(printf '%s' "${SUB:20}" | sed -E 's/(....)/\1 /g; s/ $//')"
  done < "$PROD_OUT/lines.tsv"
} | tee "$PROD_OUT/fingerprints.txt"

echo
echo "=== nothing else is automatic. Run these yourself, after reading them: ==="
echo
echo "# 1) create one Environment per line (idempotent; no secret in them)"
for L in $PROD_LINES; do
  echo "gh api -X PUT repos/QMdmm/QMdmmPackagingCi/environments/$L"
done
echo
echo "# 2) put each line's subkey secret in its own Environment (value on stdin)"
for L in $PROD_LINES; do
  echo "gh secret set SIGNING_KEY --repo QMdmm/QMdmmPackagingCi --env $L < $PROD_OUT/$L/secret.b64"
done
echo
echo "# 3) after that, delete the .asc/.b64 files - the secret is on GitHub now:"
echo "find $PROD_OUT -name 'secret.*' -delete"
echo
cat <<'NOTE'

Two things this script left open on purpose:

  - THE ROOT SECRET HAS NO BACKUP. It is unprotected, it exists in exactly one
    place, and losing this disk means the trust root is gone and every consumer
    has to be re-taught a new one. If that is not acceptable, copy the exported
    secret somewhere else before relying on it - and decide where, because an
    unprotected root secret sitting next to its own keyring is not a backup, it
    is a second copy of the same exposure.
  - The uid can be amended later without changing the key (`--edit-key adduid`),
    so a `.invalid` address today is not a permanent mistake - but every
    consumer-facing copy of the public key has to be re-published afterwards.
NOTE
