#!/usr/bin/env bash
#
# Sign a throwaway rpm package + repository metadata inside a real
# fedora container, using the per-distro subkey whose secret arrives on
# stdin as a single base64 line.
#
# Contract:
#   stdin : one line, base64 of `gpg --armor --export-secret-subkeys "<fpr>!"`
#   env   : SUB_FPR = fingerprint of this line's signing subkey
#           OUT     = output dir inside the container (default /w/out/fedora)
set -euo pipefail

# The secret arrives as $SIGNING_KEY_B64, or on stdin as a single base64 line.
# (An earlier revision blamed stdin for "not reaching the container"; a probe
#  disproved that. The real bug was dropping `base64 -d`.)
KEY_B64="${SIGNING_KEY_B64:-}"
if [ -z "$KEY_B64" ]; then
  # Read stdin FIRST - dnf below consumes it.
  IFS= read -r KEY_B64 || true
fi

SUB_FPR="${SUB_FPR:?}"
OUT="${OUT:-/w/out/fedora}"
DAILY="$OUT/daily"

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg: $(gpg --version | head -1)"
echo "  rpm: $(rpm --version)"
echo "  dnf: $(dnf --version | head -1)"

echo
echo "=== dependencies ==="
# rpmsign lives in rpm-sign, not in rpm-build (and createrepo_c does not sign
# anything by itself - the metadata signature is a plain gpg --detach-sign).
dnf install -y -q gnupg2 rpm-sign createrepo_c zstd </dev/null

echo
echo "=== import subkey from stdin ==="
printf '%s\n' "$KEY_B64" | base64 -d | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'

echo
echo "=== assert: the root secret is not usable inside this container ==="
echo "  private key files: $(ls "$HOME/.gnupg/private-keys-v1.d/" 2>/dev/null | wc -l | tr -d ' ')"
echo "  secret record types: $(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '{printf "%s ", $1}')"
ROOTFP=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
PROBE=$(mktemp)
if printf 'probe\n' | gpg --batch --local-user "${ROOTFP}!" --detach-sign -o "$PROBE" 2>/dev/null; then
  rm -f "$PROBE"; echo "  !! the primary secret can sign here"; exit 1
fi
rm -f "$PROBE"
echo "  OK: gpg refuses to sign with the primary key"
echo "  (/dev/null check after using gpg: $(ls -ld /dev/null 2>&1 | tr -s ' ' | cut -d' ' -f1,5,9))"

echo
echo "=== fetch a real, throwaway rpm to sign ==="
# rpmbuild on a trivial spec trips over Fedora's check-buildroot here, and the
# lab does not need a package we built ourselves - signing a real one that dnf
# just fetched is a better match for what the pipeline actually does.
rm -rf /tmp/rpms; mkdir -p /tmp/rpms
dnf download --destdir /tmp/rpms tree </dev/null
RPM=$(ls /tmp/rpms/*.rpm 2>/dev/null | head -1 || true)
if [ -z "$RPM" ]; then echo "  !! dnf download produced no rpm"; exit 1; fi
echo "  $RPM"
rpm -qp --qf '  before signing: %{NAME}-%{VERSION}-%{RELEASE}  sig=%{SIGPGP:pgpsig}\n' "$RPM" 2>/dev/null \
  || echo "  before signing: (no signature field)"

echo
echo "=== sign the rpm with this line's subkey (package-level signature) ==="
echo "  rpm default OpenPGP backend: $(rpm --eval '%_openpgp_sign' 2>/dev/null || echo '<unset>')"
if ! rpmsign --addsign \
      --define "_gpg_name ${SUB_FPR}" \
      --define "_openpgp_sign gpg" \
      "$RPM" 2>&1 | sed 's/^/  /'; then
  echo "  !! rpmsign with the gpg backend failed"; exit 1
fi
rpm -qp --qf '  signed: %{NAME}-%{VERSION}-%{RELEASE}  sig=%{SIGPGP:pgpsig}\n' "$RPM" 2>/dev/null || true

echo
echo "=== build repo metadata + sign it (this is what repo_gpgcheck verifies) ==="
mkdir -p "$DAILY"
cp "$RPM" "$DAILY/"
if ! createrepo_c --database --disable-deltarpm "$DAILY" > /tmp/createrepo.log 2>&1; then
  echo "  !! createrepo_c failed"; tail -20 /tmp/createrepo.log | sed 's/^/    /'; exit 1
fi
gpg --batch --yes --local-user "${SUB_FPR}!" --detach-sign --armor \
    -o "$DAILY/repodata/repomd.xml.asc" "$DAILY/repodata/repomd.xml"

echo "  --- who signed the metadata ---"
gpg --verify "$DAILY/repodata/repomd.xml.asc" "$DAILY/repodata/repomd.xml" 2>&1 | sed 's/^/    /'

echo
echo "=== output ==="
find "$OUT" -type f | sort | sed 's/^/  /'
