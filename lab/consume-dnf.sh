#!/usr/bin/env bash
#
# Stage B for the rpm format: the **dnf** consumer.
#
# Named by consumer on purpose. rpm is the package format; dnf is one of the
# programs that reads it (a later openSUSE row would reuse the same signed
# repository and need a zypper script here, not a second signing path).
#
# Consumer-side check, run inside a clean dnf-based container - fedora, rocky
# and alma all use this script. Public keys come from Pages only; this holds no
# secret at all.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA, PKGS (optional)
#
# What is checked:
#   A. day-to-day source + this line's public key   -> must PASS, and install
#   B. same source with the ROOT key only           -> must FAIL
#
# B is what establishes the two-layer split rather than assuming it: the
# repository-metadata signature is verified against a *per-repository* keyring
# built from `gpgkey=`, so pointing that at the root key must stop dnf seeing
# the repository at all - even though the subkey is in the global rpmdb by then.
#
# Two traps this script walks around on purpose:
#   - `dnf makecache` exits 0 even when metadata signature verification fails
#     (FINDINGS.md 3.2), so the assertion is "dnf can no longer list a package
#     from this repo", not "the command failed".
#   - dnf5 renamed `--qf` to `--queryformat`, so the discovery below tries both
#     instead of picking one and calling the other distro's failure a defect.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
PKGS="${PKGS:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

REPO=qmdmm-lab
REPOFILE=/etc/yum.repos.d/qmdmm.repo

# Listing a repository's packages lives in lib-site.sh: stage C needs the same
# answer, and the answer turned out to be three fallbacks rather than one guess.

write_repo() {  # write_repo <key-file>
  cat > "$REPOFILE" <<EOF
[$REPO]
name=QMdmm signing lab ($LINE $VERSION)
baseurl=$PAGES/$LINE/$VERSION
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$1
EOF
  sed 's/^/  | /' "$REPOFILE"
}

echo "=== B/dnf $LINE $VERSION ==="
echo "  $(os_name)"
echo "  rpm: $(rpm --version)   $(dnf --version 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
dnf install -y -q gnupg2 curl ca-certificates </dev/null >/dev/null 2>&1 || true
echo "  rpmsign exists: $(command -v rpmsign || echo no)"
echo "  curl: $(command -v curl || echo MISSING)"
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- take the public keys from Pages (the only channel a consumer has) ---"
fetch "$PAGES/keys/qmdmm-root.gpg"          "$W/keys/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/keys/packages.gpg"

echo
echo "--- the keys really are what the design says they are ---"
rootfpr=$(key_fpr "$W/keys/root.gpg")
nsub=$(count_subkeys "$W/keys/root.gpg")
echo "  root key file:  $rootfpr   subkeys: $nsub"
[ "$rootfpr" = "$ROOT_FPR" ] || { echo "  !! root fingerprint is not $ROOT_FPR"; exit 1; }
[ "$nsub" = 0 ] || { echo "  !! the root key file carries subkeys; it must carry none"; exit 1; }
sub=$(live_sub_fpr "$W/keys/packages.gpg")
echo "  packages key:   ${sub:-<none>}   (this line's operational subkey)"
[ -n "$sub" ] || { echo "  !! the packages key file carries no usable subkey"; exit 1; }
dead=$(dead_subkeys "$W/keys/packages.gpg")
if [ "$dead" != 0 ]; then
  echo "  (+$dead revoked subkey in the same file: this line has been rotated,"
  echo "   and dnf imports the whole file, so the live one is what verifies)"
fi
echo "  OK: root and operational keys are different keys"

echo
echo "--- A) the day-to-day source, signed by this line's subkey ---"
write_repo "$W/keys/packages.gpg"
dnf -y -q makecache > "$W/update.log" 2>&1 || true
if grep -qiE 'signature verification error|GPG check FAILED' "$W/update.log"; then
  echo "  !! metadata signature was refused:"; sed 's/^/    /' "$W/update.log"; exit 1
fi
grep -iE "qmdmm|$REPO" "$W/update.log" | sed 's/^/    /' || true

mapfile -t found < <(dnf_packages "$REPO" "$W" || true)
echo "  packages the repository serves: ${found[*]:-<none>}"
[ "${#found[@]}" -ge 1 ] || { echo "  !! the source served no qmdmm package at all"; exit 1; }
if [ -n "$PKGS" ]; then
  assert_same_set "packages served vs built" "$(built_packages "$PKGS")" "$(printf '%s\n' "${found[@]}")"
fi

mapfile -t runtime < <(printf '%s\n' "${found[@]}" | runtime_packages)
[ "${#runtime[@]}" -ge 1 ] || { echo "  !! no runtime package to install"; exit 1; }
echo "  installing: ${runtime[*]}"
dnf install -y "${runtime[@]}" > "$W/install.log" 2>&1 || {
  echo "  !! install failed:"; sed 's/^/    /' "$W/install.log"; exit 1; }
for p in "${runtime[@]}"; do
  printf '  installed: %s\n' "$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$p")"
done

echo "  package-level signatures on what dnf fetched (global rpmdb path):"
mapfile -t files < <(find /var/cache/dnf /var/cache/libdnf5 -name 'qmdmm-*.rpm' 2>/dev/null | sort || true)
if [ "${#files[@]}" -eq 0 ]; then
  echo "    (dnf kept no rpm in cache to check)"
else
  for f in "${files[@]}"; do
    if rpm -K "$f" >/dev/null 2>&1; then
      printf '    OK      %s\n' "$(basename "$f")"
    else
      printf '    !! NOT OK %s\n' "$(basename "$f")"; exit 1
    fi
  done
fi

echo
echo "--- B) the same source with the ROOT key only -> must be refused ---"
write_repo "$W/keys/root.gpg"
rm -rf /var/cache/dnf /var/cache/libdnf5
dnf clean all >/dev/null 2>&1 || true
dnf -y -q makecache > "$W/neg.log" 2>&1 || true
grep -iE 'signature verification error|GPG check FAILED' "$W/neg.log" | head -3 | sed 's/^/    /' || true
mapfile -t negfound < <(dnf_packages "$REPO" "$W" || true)
if [ "${#negfound[@]}" -ge 1 ]; then
  echo "  !! dnf still lists ${#negfound[@]} package(s) with only the root key: ${negfound[*]}"
  exit 1
fi
echo "  OK: dnf can no longer see the repository, as it must be"

echo
echo "=== B/dnf $LINE $VERSION: PASS ==="
