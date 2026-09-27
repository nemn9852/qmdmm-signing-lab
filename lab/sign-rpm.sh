#!/usr/bin/env bash
#
# Sign a throwaway rpm repository inside a real dnf-based distro container
# (fedora / rocky / alma all use this same script - signing is a property of
# the packaging format, not of the distro).
#
# Contract:
#   stdin : one line, base64 of `gpg --armor --export-secret-subkeys "<fpr>!"`
#   env   : OUT = repo root inside the container (default /w/out/rpm).
#               It maps 1:1 onto the published path, so a consumer's
#               baseurl can point straight at <pages>/<distro>.
#           LINE = distro line name (for log lines only)
set -euo pipefail

# The secret arrives as $SIGNING_KEY_B64, or on stdin as a single base64 line.
# (An earlier revision blamed stdin for "not reaching the container"; a probe
#  disproved that. The real bug was dropping `base64 -d`.)
KEY_B64="${SIGNING_KEY_B64:-}"
if [ -z "$KEY_B64" ]; then
  # Read stdin FIRST - dnf below consumes it.
  IFS= read -r KEY_B64 || true
fi

OUT="${OUT:-/w/out/rpm}"
LINE="${LINE:-rpm}"

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  line: $LINE"
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
echo "=== which subkey signs here ==="
SUB_FPR="${SUB_FPR:-}"
if [ -z "$SUB_FPR" ]; then
  mapfile -t _SUBS < <(gpg --with-colons --list-secret-keys 2>/dev/null \
                        | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
  if [ "${#_SUBS[@]}" -ne 1 ]; then
    echo "  !! expected exactly 1 usable subkey in this container, found ${#_SUBS[@]}"; exit 1
  fi
  SUB_FPR="${_SUBS[0]}"
fi
echo "  signing subkey = $SUB_FPR"

echo
echo "=== assert: the root secret is not usable inside this container ==="
echo "  private key files: $(ls "$HOME/.gnupg/private-keys-v1.d/" 2>/dev/null | wc -l | tr -d ' ')"
PROBE=$(mktemp)
ROOTFP=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
if printf 'probe\n' | gpg --batch --local-user "${ROOTFP}!" --detach-sign -o "$PROBE" 2>/dev/null; then
  rm -f "$PROBE"; echo "  !! the primary secret can sign here"; exit 1
fi
rm -f "$PROBE"
echo "  OK: gpg refuses to sign with the primary key"

echo
echo "=== fetch a real, throwaway rpm to sign (best effort) ==="
# Not every line has dnf download reachable; an empty repository still exercises
# the metadata signature, which is the half that has per-repo scope.
rm -rf /tmp/rpms; mkdir -p /tmp/rpms "$OUT"
if ! dnf download --destdir /tmp/rpms tree > /tmp/dl.log 2>&1 </dev/null; then
  echo "  (dnf download unavailable: $(tail -1 /tmp/dl.log 2>/dev/null))"
  echo "  continuing with a repository that has no packages"
fi
RPM=$(ls /tmp/rpms/*.rpm 2>/dev/null | head -1 || true)

if [ -n "$RPM" ]; then
  echo "  $RPM"
  echo
  echo "=== sign the rpm with this line's subkey (package-level signature) ==="
  echo "  rpm default OpenPGP backend: $(rpm --eval '%_openpgp_sign' 2>/dev/null || echo '<unset>')"
  # A fetched package already carries the distro's own (legacy) signature and rpm
  # refuses to stack a second one on top, so strip it first.
  rpmsign --delsign "$RPM" 2>&1 | sed 's/^/  /' || true
  if ! rpmsign --addsign --define "_gpg_name ${SUB_FPR}" "$RPM" 2>&1 | sed 's/^/  /'; then
    echo "  !! rpmsign failed"; exit 1
  fi

  echo
  echo "=== can this distro's own rpm read the signature it just made? ==="
  # rpm plus EdDSA has a history of "signs fine, verifies BAD". Ask rpm rather
  # than assume - report only, the consumer-side verdict is the verify job's job.
  gpg --batch --armor --export "${SUB_FPR}!" > /tmp/pub.asc
  rpm --import /tmp/pub.asc > /dev/null 2>&1 || true
  if rpm -Kv "$RPM" > /tmp/rpmk.log 2>&1; then
    echo "  rpm -K: OK"
  else
    echo "  rpm -K: NOT OK"
  fi
  grep -iE 'signature|digest' /tmp/rpmk.log 2>/dev/null | head -4 | sed 's/^/    /' || true
  rpm -qp --qf '  rpm reads the signature as: %{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}\n' "$RPM" 2>/dev/null || true

  cp "$RPM" "$OUT/"
fi

echo
echo "=== build repo metadata + sign it (this is what repo_gpgcheck verifies) ==="
if ! createrepo_c "$OUT" > /tmp/createrepo.log 2>&1; then
  echo "  !! createrepo_c failed"; tail -20 /tmp/createrepo.log | sed 's/^/    /'; exit 1
fi
gpg --batch --yes --local-user "${SUB_FPR}!" --detach-sign --armor \
    -o "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml"

echo "  --- who signed the metadata ---"
gpg --verify "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml" 2>&1 | sed 's/^/    /'

echo
echo "=== output ==="
find "$OUT" -type f | sort | sed 's/^/  /'
