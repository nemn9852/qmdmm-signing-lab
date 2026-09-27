#!/usr/bin/env bash
#
# fedora:43 rejects repo_gpgcheck in all six shapes (2 algorithms x {subkey,
# primary, no-subkey-and-primary}), while rocky:10 accepts all of them. So the
# remaining question is the fallback: does the PACKAGE-level path work there -
# and specifically, can this rpm read a key of each type at all?
#
# That is also the old 'EdDSA signs fine, installs badly' question, so ask it
# directly instead of inheriting it:
#
#   1. rpm --import <armored public key>            (does rpm accept the key?)
#   2. sign a real package with this line's subkey   (rpmsign)
#   3. rpm -K the result                             (does rpm verify it?)
#
# Diagnostic: no `set -e`.
set -uo pipefail

LINE="${LINE:-rpm}"
ALGO="${ALGO:-ed25519}"
W=/tmp/pkgcheck

echo "=== $LINE / $ALGO: package-level path ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  rpm: $(rpm --version)   dnf: $(dnf --version | head -1)   gpg: $(gpg --version | head -1)"
echo "  rpm OpenPGP backend: $(rpm --eval '%_openpgp_sign' 2>/dev/null || echo '<unset>')"

dnf install -y -q gnupg2 rpm-sign </dev/null >/dev/null 2>&1 || true

export GNUPGHOME=$W/home
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
    "pkgcheck $ALGO <p@example.invalid>" "$ALGO" sign 0 >/dev/null 2>&1
ROOT=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
gpg --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$ROOT" "$ALGO" sign 0 >/dev/null 2>&1
SUB=$(gpg --with-colons --list-secret-keys "$ROOT" 2>/dev/null \
      | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
echo "  primary $ROOT"
echo "  subkey  $SUB"

gpg --batch --armor --export "$ROOT" > "$W/pub.asc" 2>/dev/null
gpg --batch --export "$ROOT"        > "$W/pub.gpg" 2>/dev/null
echo "  exported: pub.asc $(wc -c < "$W/pub.asc" | tr -d ' ')B   pub.gpg $(wc -c < "$W/pub.gpg" | tr -d ' ')B"

echo
echo "--- 1. rpm --import, armored vs binary ---"
for pair in "armored:$W/pub.asc" "binary:$W/pub.gpg"; do
  tag="${pair%%:*}"; f="${pair##*:}"
  out=$(rpm --import "$f" 2>&1); rc=$?
  printf '    %-8s rc=%s  %s\n' "$tag" "$rc" "${out:-<no output>}"
done
printf '    rpmdb now: %s\n' "$(rpm -qa 'gpg-pubkey*' 2>/dev/null | tr '\n' ' ')"
printf '    our key in rpmdb? '
if rpm -qa 'gpg-pubkey*' 2>/dev/null | grep -qi "$(echo "$ROOT" | tail -c 9)"; then echo yes; else echo no; fi

echo
echo "--- 2. fetch a real rpm and re-sign it with this line's subkey ---"
rm -rf "$W/rpms"; mkdir -p "$W/rpms"
dnf download --destdir "$W/rpms" tree >/dev/null 2>&1
RPM=$(ls "$W/rpms"/*.rpm 2>/dev/null | head -1)
if [ -z "$RPM" ]; then echo "    !! dnf download produced no rpm"; exit 0; fi
echo "    $RPM"
cp "$RPM" "$W/unsigned.rpm"
rpm --delsign "$W/unsigned.rpm" >/dev/null 2>&1
sign_out=$(rpmsign --addsign --define "_gpg_name ${SUB}" "$W/unsigned.rpm" 2>&1); sign_rc=$?
printf '    rpmsign rc=%s  %s\n' "$sign_rc" "$(printf '%s' "$sign_out" | head -2 | tr '\n' ' ')"

echo
echo "--- 3. verify the signed package with rpm itself ---"
echo "    (a) with the key in the rpmdb (the gpgcheck=1 path)"
q=$(rpm -K "$W/unsigned.rpm" 2>&1); rcv=$?
printf '        rpm -K rc=%s\n' "$rcv"
printf '%s\n' "$q" | sed 's/^/        | /'
echo "    (b) with the key taken away, same file"
rpm -e "$(rpm -qa 'gpg-pubkey*' 2>/dev/null | grep -i "$(echo "$ROOT" | tail -c 9)" | head -1)" >/dev/null 2>&1
q2=$(rpm -K "$W/unsigned.rpm" 2>&1); rcv2=$?
printf '        rpm -K rc=%s\n' "$rcv2"
printf '%s\n' "$q2" | sed 's/^/        | /'

echo
echo "=== read this as ==="
echo "  (a) NOKEY/DIGESTS vs OK  -> package signing works (or not) on this rpm"
echo "  armored-only import      -> rpm wants armor; binary is a caller error"
