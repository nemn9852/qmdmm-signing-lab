#!/usr/bin/env bash
#
# Run this on a trusted machine, NOT in CI.
#
# Builds the rpm line's trust artefact - `<vendor>-release` in Fedora/EPEL
# spelling - and the ROOT-signed repository that serves it. It is the rpm
# counterpart of mkkeyring-deb.sh, and the reason sign-repo-rpm.sh's header says
# the keyring package "is NOT built here" is this file: the thing that makes the
# package trustworthy is the root key's signature over the repository metadata,
# and the root secret never enters a workflow.
#
# Two repositories, not one, exactly as on the apt side:
#
#   <pages>/<line>-keyring      ROOT-signed. Ships exactly one package.
#   <pages>/<line>/<version>    subkey-signed. The day-to-day source, built by
#                               stage S in CI.
#
# The package carries:
#   /etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-<line>   armored root + this line's subkey
#   /etc/yum.repos.d/qmdmm.repo                 %config(noreplace), names the above
#
# There is deliberately no signature on the .rpm itself. rpm packages are
# reviewed by dnf against the global rpmdb, and this one is fetched before the
# consumer has any key at all; what protects it is that it is served from the
# root-signed source, whose repomd.xml only the root key can sign - and a
# tampered package is refused by the signed checksum in that metadata. That is
# the same argument as the .deb's, and it is why the bootstrap stanza the
# consumer writes needs `repo_gpgcheck=1` with `gpgcheck=0` rather than the
# other way round.
#
# Where the two halves run, and why:
#
#   this machine   holds the root secret, so it signs. It has no rpmbuild and no
#                  createrepo_c (no Homebrew formula for the latter), so
#   the builder    builds the package and the repodata. Nothing secret goes
#                  there: the payload is public key material and a text file.
#
# The split is the point rather than an accident, and it is the same shape the
# deb side has - the artefact is assembled where the root key is, while the
# thing being assembled needs no key at all.
#
# usage: mkkeyring-rpm.sh <line> <version> [pages-base]
# env:   RPM_BUILDER  ssh target that has rpmbuild and createrepo_c
#                     (default neve@10.31.42.18; set to "local" if this machine
#                      has both)
set -euo pipefail

cd "$(dirname "$0")/.."                      # -> repo/
source "$HOME/qmdmm-signing-lab/env.sh"      # GNUPGHOME, ROOT
source lab/lib-site.sh                       # key_fpr

LINE="${1:?usage: mkkeyring-rpm.sh <line> <version> [pages-base]}"
VERSION="${2:?usage: mkkeyring-rpm.sh <line> <version> [pages-base]}"
BASE="${3:-$LAB_PAGES}"
BUILDER="${RPM_BUILDER:-neve@10.31.42.18}"

PKG="qmdmm-release-$LINE-$VERSION"
KEYNAME="RPM-GPG-KEY-qmdmm-$LINE"
OUT="site/$LINE-keyring"

[ -f "keys/$LINE/qmdmm-packages.gpg" ] || { echo "!! keys/$LINE/qmdmm-packages.gpg missing"; exit 1; }
[ -f keys/qmdmm-root.gpg ]             || { echo "!! keys/qmdmm-root.gpg missing"; exit 1; }

echo "=== keyring source for $LINE $VERSION ==="
echo "  builder: $BUILDER"
echo "  pages:   $BASE"
echo "  package: $PKG"

# The root secret is what this file exists to use, so its presence is asserted
# rather than assumed - and it has to be *the* root key, not whichever key
# happens to be first in the keyring. A missing or wrong key here would produce
# a repository signed by something else, and the consumer cell would report it
# as a broken scheme rather than as a wrong keyring.
echo
echo "--- the root secret, which is why this runs off-CI ---"
mapfile -t SECS < <(gpg --with-colons --list-secret-keys 2>/dev/null \
                    | awk -F: '/^sec:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
[ "${#SECS[@]}" -eq 1 ] || { echo "  !! expected exactly 1 secret key in $GNUPGHOME, found ${#SECS[@]}"; exit 1; }
[ "${SECS[0]}" = "$ROOT" ] || { echo "  !! the secret key is ${SECS[0]}, not the root key $ROOT"; exit 1; }
echo "  root: $ROOT  (the only secret key here)"

# `root-fpr!` is the trailing bang that limits gpg to the primary key. Without
# it a subkey would be an acceptable signer, and "only the root key may sign the
# keyring source" would be a claim about the file rather than about the
# signature.
ROOT_KEYID="${ROOT: -16}"

WORK=$(mktemp -d); RDIR=""
cleanup() {
  rm -rf "$WORK"
  # The staging directory is on the builder, so it needs removing there too -
  # including on the failure path, which is the one that used to leave it behind.
  if [ -n "$RDIR" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" "rm -rf '$RDIR'" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/payload"

echo
echo "--- the payload: public key material and a text file ---"
# Which public key goes in depends on the format, and the two answers are
# opposite. On deb the key file keeps the outgoing subkey on purpose, because
# gpgv reads the revocation certificate and says "revoked" instead of "unknown
# key". On rpm nothing reads it - dnf neither consults the certificate nor
# reports the state (FINDINGS 10.7) - so carrying it buys no diagnosis and costs
# the revocation, which is 10.9's conclusion: publish the pruned file.
KEYSRC="keys/$LINE/qmdmm-packages.gpg"
if [ -f "keys/$LINE/qmdmm-packages-pruned.gpg" ]; then
  KEYSRC="keys/$LINE/qmdmm-packages-pruned.gpg"
  echo "  this line has been rotated: shipping the pruned key file (FINDINGS 10.9)"
fi
echo "  source key: $KEYSRC"
# Armored, because `rpm --import` wants armor and refuses the binary export
# (FINDINGS 3.7) - the one finding on this side that has already cost a round.
GH="$WORK/gh"; mkdir -p "$GH"; chmod 700 "$GH"
gpg --homedir "$GH" --batch --quiet --import "$KEYSRC" 2>/dev/null
gpg --homedir "$GH" --armor --export > "$STAGE/payload/$KEYNAME"
sz=$(wc -c < "$STAGE/payload/$KEYNAME" | tr -d ' ')
[ "$sz" -gt 500 ] || { echo "  !! the armored key file is only $sz bytes"; exit 1; }
dead=$(gpg --with-colons --show-keys "$STAGE/payload/$KEYNAME" 2>/dev/null \
       | awk -F: '/^sub:/{if ($2 ~ /^[redi]$/) n++} END{print n+0}')
echo "  payload/$KEYNAME  $sz bytes, armored, $dead unusable subkey(s)"
[ "$dead" = 0 ] || { echo "  !! the shipped key file carries a revoked subkey"; exit 1; }

cat > "$STAGE/payload/qmdmm.repo" <<EOF
[qmdmm]
name=QMdmm packages ($LINE $VERSION)
baseurl=$BASE/$LINE/$VERSION
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/$KEYNAME
EOF
sed 's/^/  | /' "$STAGE/payload/qmdmm.repo"

cat > "$STAGE/qmdmm-release.spec" <<EOF
# Generated by lab/mkkeyring-rpm.sh. The version is in the package name on
# purpose: this file configures one line at one version, and two of them must
# not be silently interchangeable.
# License is a placeholder - the package is a public key and a repository URL.
Name:           $PKG
Version:        1.0
Release:        1
Summary:        QMdmm repository key and configuration ($LINE $VERSION)
License:        CC0-1.0
BuildArch:      noarch

%description
Ships the QMdmm signing key for the $LINE line together with the yum
repository definition that names it, so that installing this package both
trusts and enables the repository at $BASE/$LINE/$VERSION.

%prep

%build

%install
install -d "%{buildroot}/etc/pki/rpm-gpg" "%{buildroot}/etc/yum.repos.d"
install -m 0644 %{_sourcedir}/$KEYNAME "%{buildroot}/etc/pki/rpm-gpg/$KEYNAME"
install -m 0644 %{_sourcedir}/qmdmm.repo "%{buildroot}/etc/yum.repos.d/qmdmm.repo"

%files
%config(noreplace) /etc/yum.repos.d/qmdmm.repo
/etc/pki/rpm-gpg/$KEYNAME

%changelog
* Thu Oct 01 2026 QMdmm signing lab <lab@example.invalid> - 1.0-1
- built by lab/mkkeyring-rpm.sh
EOF

# What runs over there. Written into the payload rather than piped through an
# interpolating heredoc, so that no quoting layer sits between this file and
# what the builder executes.
cat > "$STAGE/remote.sh" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"
echo "  rpmbuild: $(rpmbuild --version)"
echo "  createrepo_c: $(createrepo_c --version)"

T="$PWD/rpmbuild"
rm -rf "$T"; mkdir -p "$T"/SPECS "$T"/SOURCES "$T"/BUILD "$T"/BUILDROOT "$T"/RPMS "$T"/SRPMS
cp payload/* "$T/SOURCES/"

rpmbuild --define "_topdir $T" -bb qmdmm-release.spec > "$PWD/rpmbuild.log" 2>&1 || {
  echo "  !! rpmbuild failed:"; tail -25 "$PWD/rpmbuild.log" | sed 's/^/    /'; exit 1; }
grep -E '^Wrote:' "$PWD/rpmbuild.log" | sed 's/^/  /'

OUT="$PWD/out"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$T"/RPMS/noarch/*.rpm "$OUT"/
ls -l "$OUT"/*.rpm | awk '{printf "  built: %s  (%s bytes)\n", $NF, $5}'

# Assert the payload really is in it, rather than trusting the build log. The
# key file's name is read back out of the package rather than globbed: a glob in
# a `for` list expands against THIS machine's filesystem, so it would compare
# against a literal asterisk here and fail for a reason the log does not name.
rpm -qlp "$OUT"/*.rpm > contents.txt
echo "  contents:"
sed 's/^/    /' contents.txt
grep -qx '/etc/yum.repos.d/qmdmm.repo' contents.txt \
  || { echo "  !! the package does not carry /etc/yum.repos.d/qmdmm.repo"; exit 1; }
grep -qE '^/etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-.+$' contents.txt \
  || { echo "  !! the package carries no RPM-GPG-KEY-qmdmm-* file"; exit 1; }

createrepo_c "$OUT" >/dev/null
echo "  repodata:"
find "$OUT/repodata" -type f | sort | sed 's/^/    /'
REMOTE

echo
echo "--- build the package and the repodata on the builder ---"
if [ "$BUILDER" = local ]; then
  ( cd "$STAGE" && bash remote.sh )
else
  RDIR=/tmp/qmdmm-keyring-$$-$RANDOM
  # --no-xattrs: macOS tar otherwise writes the BSD xattr headers, and GNU tar on
  # the far side answers each one with an "unknown extended header keyword"
  # warning that buries the real build output.
  tar --no-xattrs -C "$STAGE" -cf - . \
    | ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" \
        "rm -rf $RDIR && mkdir -p $RDIR && tar --warning=no-unknown-keyword -C $RDIR -xf -" \
    || { echo "  !! cannot stage the build on $BUILDER"; exit 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" "cd $RDIR && bash remote.sh" || {
    echo "  !! the build failed on $BUILDER"; exit 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BUILDER" "tar -C $RDIR/out -cf - ." > "$WORK/out.tar" \
    || { echo "  !! cannot collect the build from $BUILDER"; exit 1; }
fi

echo
echo "--- stage it at its published path ---"
rm -rf "$OUT"; mkdir -p "$OUT"
if [ "$BUILDER" = local ]; then
  cp -r "$STAGE/out/." "$OUT/"
else
  tar -C "$OUT" -xf "$WORK/out.tar"
fi
find "$OUT" -type f | sort | sed 's/^/  /'
[ -f "$OUT/repodata/repomd.xml" ] \
  || { echo "  !! no repodata/repomd.xml came back from the builder"; exit 1; }

echo
echo "--- sign the metadata with the ROOT key ---"
gpg --batch --yes --local-user "${ROOT}!" --armor --detach-sign \
    -o "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml"
chmod 644 "$OUT/repodata/repomd.xml.asc" "$OUT"/*.rpm

# Which key signed it, from the status stream rather than from the exit code:
# `gpg --verify` calls a signature good whatever key made it, so the exit code
# cannot tell the root key from a subkey (FINDINGS 3.1 is the same shape).
gpgv --keyring keys/qmdmm-root.gpg --status-fd 3 \
     "$OUT/repodata/repomd.xml.asc" "$OUT/repodata/repomd.xml" 3> "$WORK/status" || true
signer=$(awk '/^\[GNUPG:\] GOODSIG /{print $3}' "$WORK/status" | head -1)
echo "  signer: ${signer:-<none>}   expected: $ROOT_KEYID"
[ "$signer" = "$ROOT_KEYID" ] \
  || { echo "  !! the keyring source is not signed by the root key"; exit 1; }
echo "  OK: the keyring source verifies under the root key alone"

# The armored form of the root key, so a consumer can follow rpm's own
# convention (`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-...`) with the file
# the site publishes rather than with a conversion it does itself.
#
# `"$ROOT!"`, with the bang, and it is not decoration. The line keys are
# SUBKEYS of the root key, so a plain `--export "$ROOT"` emits the primary key
# together with every line's signing subkey. A consumer handed that file can
# verify a day-to-day source it was never supposed to be able to read, and the
# two-layer split - root signs the keyring source, the line's subkey signs the
# day-to-day one - stops being a property of the keys and becomes a property of
# the file. It is invisible in step A of the consumer cell, because the keyring
# source is signed by the primary key and that is in both files; it only shows
# up one step later. consume-dnf.sh has asserted `subkeys: 0` on the deb-side
# pin since it was first written; this file did not, and run 36836722274 is
# what that cost - both rpm cells, on the very same assertion, in the very same
# words. The three checks below are that assertion plus the two ways a
# regenerated pin can drift from the key it claims to be.
gpg --batch --yes --armor --export "$ROOT!" > keys/qmdmm-root.asc
chmod 644 keys/qmdmm-root.asc
ascsz=$(wc -c < keys/qmdmm-root.asc | tr -d ' ')
ascfpr=$(key_fpr keys/qmdmm-root.asc)
ascsub=$(count_subkeys keys/qmdmm-root.asc)
echo "  keys/qmdmm-root.asc  $ascsz bytes, $ascfpr, $ascsub subkey(s)"
[ "$ascfpr" = "$ROOT" ] \
  || { echo "  !! the armored root pin is $ascfpr, not the root key $ROOT"; exit 1; }
[ "$ascsub" = 0 ] \
  || { echo "  !! the armored root pin carries $ascsub subkey(s); it must carry none"; exit 1; }
# And it has to be the same key the deb and pacman cells are handed: two
# published encodings of one pin, never two pins. A rebuild that picked up a
# different keyring would satisfy the two checks above and still be wrong.
gpg --dearmor < keys/qmdmm-root.asc | cmp -s - keys/qmdmm-root.gpg \
  || { echo "  !! the armored root pin is not the same key as keys/qmdmm-root.gpg"; exit 1; }

echo
echo "=== built $OUT ==="
echo "  NEXT: if the package changed, re-run this for the other lines, then:"
echo "    git add $OUT keys/qmdmm-root.asc && git commit && git push"
echo "  and dispatch signing-lab.yml to have a consumer install it:"
echo "    lab/consume-dnf-keyring-package.sh in the rpm cell is that reading."
