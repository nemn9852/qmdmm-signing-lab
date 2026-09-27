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

# The secret arrives either as $SIGNING_KEY_B64, or on stdin as a single
# base64 line. In GitHub Actions the stdin route never reaches the container,
# so the env route is the one used there.
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
dnf install -y -q gnupg2 rpm-build createrepo_c zstd </dev/null

echo
echo "=== import subkey from stdin ==="
printf '%s\n' "$KEY_B64" | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'

echo
echo "=== assert: no usable primary secret in this container ==="
if gpg --list-secret-keys --with-colons | awk -F: '$1=="sec" && $2!="e"' | grep -q .; then
  echo "  !! a usable primary secret is present"; exit 1
fi
echo "  OK"

echo
echo "=== build a throwaway rpm ==="
TOP=/tmp/rpmbuild
mkdir -p "$TOP/BUILD" "$TOP/RPMS" "$TOP/SOURCES" "$TOP/SPECS" "$TOP/SRPMS"
cat > "$TOP/SPECS/lab.spec" <<'SPEC'
Name:           qmdmm-lab
Version:        1.0
Release:        1
Summary:        QMdmm signing lab test package
License:        MIT
BuildArch:      noarch

%description
Disposable test package for the QMdmm signing lab.

%prep
%build
%install
mkdir -p %{buildroot}/usr/share/qmdmm-lab
printf 'lab\n' > %{buildroot}/usr/share/qmdmm-lab/README

%files
/usr/share/qmdmm-lab/README

%changelog
* Sun Sep 27 2026 Lab <lab@example.invalid> - 1.0-1
- initial
SPEC
if ! rpmbuild -bb --define "_topdir $TOP" "$TOP/SPECS/lab.spec" > /tmp/rpmbuild.log 2>&1; then
  echo "  !! rpmbuild failed"; tail -25 /tmp/rpmbuild.log | sed 's/^/    /'; exit 1
fi
RPM=$(find "$TOP/RPMS" -name '*.rpm' | head -1)
echo "  $RPM"

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
