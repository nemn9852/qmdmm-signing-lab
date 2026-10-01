#!/usr/bin/env bash
#
# Stage B for the rpm trust bootstrap: install the `*-release` package, and check
# that a user ends up with a working repository.
#
# The deb counterpart is consume-keyring-package.sh. This is the rpm half of the
# mechanism FINDINGS 10.8 lists as "a mechanism not yet built", and the reason it
# is a separate script rather than a branch in consume-dnf.sh is that
# consume-dnf.sh starts from a repository a consumer already trusts; this one
# starts from nothing but a key fingerprint read off the website.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA, PKGS (optional)
#
# What is checked:
#   0. the keyring source's metadata really is signed by the ROOT key - read
#      straight off the published bytes, so that the claim does not depend on
#      dnf agreeing
#   A. holding only the ROOT key, the keyring source is readable and it offers
#      this line's release package - the one bootstrap step a user does by hand
#   A'. the same ROOT key against the DAY-TO-DAY source is not enough: the
#      subkey, and only the subkey, may sign that one
#   B. the package brings the line's key and the repository definition with it,
#      and the key file it ships really is this line's operational subkey
#   C. with the hand-made stanza removed, the repository still works on nothing
#      but the package's own configuration
#
# C is the point, exactly as on the deb side: a `*-release` package that installs
# but configures nothing is indistinguishable from a working one right up to the
# moment a user tries to use it.
#
# Two dnf behaviours are walked around on purpose rather than trusted:
#   - `dnf makecache` exits 0 when metadata verification fails (FINDINGS 3.2),
#     so no assertion below is on an exit code.
#   - dnf5 refuses a repository it cannot verify **in silence** (FINDINGS 3.15),
#     so the negative half of every pair is an assertion that the package list
#     is EMPTY, and the positive half that it is not. An absence of an error
#     message is not one of the readings.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
PKGS="${PKGS:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys" "$W/gh"; chmod 700 "$W/gh"
source "$(dirname "$0")/lib-site.sh"

PKG="qmdmm-release-$LINE-$VERSION"
KEYNAME="RPM-GPG-KEY-qmdmm-$LINE"
KEYFILE="/etc/pki/rpm-gpg/$KEYNAME"
REPOFILE=/etc/yum.repos.d/qmdmm.repo
BOOT=qmdmm-bootstrap
NEG=qmdmm-neg

echo "=== B/keyring-package (rpm) $LINE $VERSION ==="
echo "  $(os_name)"
echo "  rpm: $(rpm --version)   $(dnf --version 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 curl ca-certificates </dev/null >/dev/null 2>&1 || true
command -v gpg >/dev/null || { echo "  !! gpg is missing; the key checks are written against it"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- keys, from Pages only ---"
# Armored, which is the form rpm's own convention uses for a key file
# (`RPM-GPG-KEY-*`) and the form `rpm --import` accepts (FINDINGS 3.7).
fetch "$PAGES/keys/qmdmm-root.asc"      "$W/keys/root.asc"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/keys/packages.gpg"
rootfpr=$(key_fpr "$W/keys/root.asc")
[ "$rootfpr" = "$ROOT_FPR" ] || { echo "  !! the published root key is $rootfpr, not $ROOT_FPR"; exit 1; }
sub=$(live_sub_fpr "$W/keys/packages.gpg")
[ -n "$sub" ] || { echo "  !! the line's key file carries no usable subkey"; exit 1; }
echo "  root: ${ROOT_FPR: -16}   line subkey: ${sub: -16}"

echo
echo "--- 0) the keyring source, verified against the published bytes ---"
# Independent of dnf: stage A of the trust chain is a claim about a signature,
# and dnf's cooperation is then a separate reading in A below.
fetch "$PAGES/$LINE-keyring/repodata/repomd.xml"     "$W/repomd.xml"
fetch "$PAGES/$LINE-keyring/repodata/repomd.xml.asc" "$W/repomd.xml.asc"
gpg --homedir "$W/gh" --batch --quiet --import "$W/keys/root.asc" 2>/dev/null
gpg --homedir "$W/gh" --status-fd 3 --verify "$W/repomd.xml.asc" "$W/repomd.xml" \
    3> "$W/status" > "$W/gpgv.log" 2>&1 || true
signer=$(awk '/^\[GNUPG:\] GOODSIG /{print $3}' "$W/status" | head -1)
echo "  signer: ${signer:-<none>}   expected: ${ROOT_FPR: -16}"
[ "$signer" = "${ROOT_FPR: -16}" ] \
  || { echo "  !! the keyring source is not signed by the root key:"; sed 's/^/    /' "$W/gpgv.log"; exit 1; }
echo "  OK: signed by the root key, and the signature is over these bytes"

install -d -m 755 /etc/pki/rpm-gpg
install -m 644 "$W/keys/root.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-root

echo
echo "--- A) the one manual step: the root-signed source, under the ROOT key alone ---"
cat > "/etc/yum.repos.d/$BOOT.repo" <<EOF
[$BOOT]
name=QMdmm keyring source ($LINE)
baseurl=$PAGES/$LINE-keyring
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-root
EOF
sed 's/^/  | /' "/etc/yum.repos.d/$BOOT.repo"
dnf -y -q makecache > "$W/a.log" 2>&1 || true
if grep -qiE 'signature verification error|GPG check FAILED' "$W/a.log"; then
  echo "  !! metadata signature was refused:"; sed 's/^/    /' "$W/a.log"; exit 1
fi
mapfile -t offered < <(dnf_packages "$BOOT" "$W" || true)
echo "  the keyring source offers: ${offered[*]:-<nothing>}"
[ "${#offered[@]}" -eq 1 ] && [ "${offered[0]}" = "$PKG" ] \
  || { echo "  !! expected the keyring source to offer exactly $PKG"; exit 1; }

echo
echo "--- A') the DAY-TO-DAY source with the ROOT key only -> must serve nothing ---"
# The negative half of the two-layer split, and the reason it comes before the
# package is installed: a repository that verifies under either key would make
# "the subkey is what signs this line" an untested sentence.
cat > "/etc/yum.repos.d/$NEG.repo" <<EOF
[$NEG]
name=QMdmm day-to-day ($LINE $VERSION), root key only
baseurl=$PAGES/$LINE/$VERSION
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-qmdmm-root
EOF
rm -rf /var/cache/dnf /var/cache/libdnf5
dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/neg.log" 2>&1 || true
grep -iE 'signature verification error|GPG check FAILED' "$W/neg.log" | head -3 | sed 's/^/    /' || true
mapfile -t negfound < <(dnf_packages "$NEG" "$W" || true)
if [ "${#negfound[@]}" -ge 1 ]; then
  echo "  !! dnf lists ${#negfound[@]} package(s) from the day-to-day source with only the root key: ${negfound[*]}"
  exit 1
fi
echo "  OK: the root key alone cannot read the day-to-day source"
rm -f "/etc/yum.repos.d/$NEG.repo"

echo
echo "--- install it ---"
if ! dnf -y -q install "$PKG" > "$W/install.log" 2>&1; then
  echo "  !! installing $PKG failed:"; sed 's/^/    /' "$W/install.log"; exit 1
fi
rpm -q --qf '  installed: %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$PKG"

echo
echo "--- B) what the package actually put on disk ---"
rpm -ql "$PKG" | sed 's/^/    /'
for f in "$REPOFILE" "$KEYFILE"; do
  [ -f "$f" ] || { echo "  !! $PKG did not ship $f"; exit 1; }
  printf '    %s  (%s bytes, mode %s)\n' "$f" "$(wc -c < "$f" | tr -d ' ')" "$(stat -c '%a' "$f")"
done
echo "  --- $REPOFILE ---"
sed 's/^/    /' "$REPOFILE"
for want in "baseurl=$PAGES/$LINE/$VERSION" 'gpgcheck=1' 'repo_gpgcheck=1' "gpgkey=file://$KEYFILE"; do
  grep -qxF "$want" "$REPOFILE" || { echo "  !! the repository definition is missing: $want"; exit 1; }
done
echo "  OK: it enables the day-to-day source and names its own key file"

# The key the package ships must be THIS line's key, and specifically the subkey
# that is currently able to sign - a package carrying the root key, or a key
# from another line, would still satisfy everything above.
shipped=$(live_sub_fpr "$KEYFILE")
echo "  key file: shipped subkey ${shipped: -16}   line subkey $(printf '%s' "$sub" | tail -c 17)"
[ "$shipped" = "$sub" ] \
  || { echo "  !! the package ships a different key than the line's operational subkey"; exit 1; }

# And it must carry no subkey that can no longer sign. This is the one place the
# rpm answer differs from the deb answer, so it is asserted rather than left to
# the builder: on deb the key file deliberately keeps the outgoing subkey, since
# gpgv reads the revocation certificate; on rpm nothing does (FINDINGS 10.7), so
# a retained subkey only means a leaked key that still signs (FINDINGS 10.9).
dead=$(dead_subkeys "$KEYFILE")
echo "  unusable subkeys in the shipped key file: $dead"
[ "$dead" = 0 ] \
  || { echo "  !! the shipped key file carries a revoked subkey; publish the pruned one"; exit 1; }

echo
echo "--- C) drop the hand-made stanza: everything must come from the package now ---"
rm -f "/etc/yum.repos.d/$BOOT.repo"
leftover=$(cd /etc/yum.repos.d && ls | grep -i qmdmm || true)
echo "  qmdmm repository files left: $(printf '%s' "$leftover" | tr '\n' ' ')"
[ "$leftover" = "qmdmm.repo" ] \
  || { echo "  !! expected only the package's own qmdmm.repo to remain"; exit 1; }
rm -rf /var/cache/dnf /var/cache/libdnf5
dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/c.log" 2>&1 || true

mapfile -t found < <(dnf_packages qmdmm "$W" || true)
echo "  packages the day-to-day source serves: ${found[*]:-<none>}"
# Positive, and that is the point: dnf5 reports a repository it cannot verify by
# saying nothing at all, so "no error appeared" would pass on a total failure.
[ "${#found[@]}" -ge 1 ] || { echo "  !! the source served no qmdmm package at all"; exit 1; }
if [ -n "$PKGS" ]; then
  assert_same_set "packages served vs built" "${found[@]}" "$(built_packages "$PKGS")"
fi

mapfile -t runtime < <(printf '%s\n' "${found[@]}" | grep -v "^$PKG$" | runtime_packages)
[ "${#runtime[@]}" -ge 1 ] || { echo "  !! no runtime package to install"; exit 1; }
echo "  installing: ${runtime[*]}"
if ! dnf install -y "${runtime[@]}" > "$W/install2.log" 2>&1; then
  echo "  !! install from the package's own configuration failed:"; sed 's/^/    /' "$W/install2.log"; exit 1
fi
for p in "${runtime[@]}"; do
  printf '  installed: %s\n' "$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$p")"
done

echo
echo "=== B/keyring-package (rpm) $LINE $VERSION: PASS ==="
