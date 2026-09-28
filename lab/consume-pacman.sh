#!/usr/bin/env bash
#
# Stage B for the pacman format: the **pacman** consumer.
#
# Named by consumer on purpose. pacman is the program that reads what stage S
# produced (a database plus its detached signature); the format is the tarball
# inside. Arch and Manjaro both use this script.
#
# Consumer-side check, run inside a clean archlinux:base / manjarolinux:base
# container. Public keys come from Pages only; this holds no secret at all.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA, PKGS (optional)
#
# What is checked:
#   A. day-to-day source + this line's subkey, locally signed -> must PASS, and install
#   B. the same source with only the ROOT key locally signed  -> must FAIL
#
# pacman has no per-repository trust scope (FINDINGS.md §6): trust is granted
# out of band with `pacman-key --lsign-key`, so the only thing that makes the
# day-to-day database acceptable is having signed *that* subkey locally. B is
# therefore the whole test - if pacman accepted the database while only the root
# key was signed, the per-line subkey would prove nothing here.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
PKGS="${PKGS:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys"
source "$(dirname "$0")/lib-site.sh"

# The database stage S builds is always lab.db, so the section name is fixed.
REPO=lab

echo "=== B/pacman $LINE $VERSION ==="
echo "  $(os_name)"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "--- mirrorlist (left alone unless it has no server at all) ---"
# Only fill an empty mirrorlist. Overwriting it unconditionally would point
# Manjaro at Arch's mirrors, where none of Manjaro's own packages exist.
if ! grep -qE '^\s*Server' /etc/pacman.d/mirrorlist; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
grep -E '^\s*Server' /etc/pacman.d/mirrorlist | head -3 | sed 's/^/  /'

echo
echo "--- tooling ---"
# Asking for `archlinux-keyring` by name would fail on the Manjaro row (that
# package does not exist there), and pacman installs all-or-nothing, so the
# failure would have taken gnupg and curl down with it.
pacman -Sy --noconfirm --needed gnupg curl ca-certificates >/dev/null 2>&1 \
  || pacman -S --noconfirm --needed gnupg curl ca-certificates-mozilla >/dev/null 2>&1 || true
command -v gpg  >/dev/null || { echo "  !! gpg is missing"; exit 1; }
command -v curl >/dev/null || { echo "  !! curl is missing"; exit 1; }
assert_tls "$PAGES/publish.json" || exit 1
# `pacman-key --lsign-key` has to SIGN with the local keyring's master key, so
# the question is not "is there a keyring" - Arch's base image ships one, filled
# with the distribution's public keys and with no secret key at all. Without
# this, --lsign-key dies with "There is no secret key available to sign with",
# which is a message about the keyring and looks nothing like the actual
# problem: a container that has never needed to sign anything.
if ! gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec'; then
  echo "  (the pacman keyring has no secret key; creating one)"
  pacman-key --init
  gpg --homedir /etc/pacman.d/gnupg --list-secret-keys 2>/dev/null | grep -q '^sec' \
    || { echo "  !! pacman-key --init did not produce a key this keyring can sign with"; exit 1; }
fi
echo "  pacman keyring can sign: yes"
echo "  gpg:   $(command -v gpg)"
echo "  curl:  $(command -v curl)"
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
sub=$(first_sub_fpr "$W/keys/packages.gpg")
echo "  packages key:   $sub   (this line's operational subkey)"
[ -n "$sub" ] || { echo "  !! the packages key file carries no subkey"; exit 1; }
echo "  OK: root and operational keys are different keys"

echo
echo "--- A) trust this line's subkey locally, then read the database ---"
pacman-key --add "$W/keys/packages.gpg" 2>&1 | sed 's/^/    /'
pacman-key --lsign-key "$sub" 2>&1 | sed 's/^/    /'
cat >> /etc/pacman.conf <<EOF

[$REPO]
SigLevel = Required DatabaseRequired
Server = $PAGES/$LINE/$VERSION
EOF
echo "  | [$(tail -4 /etc/pacman.conf | head -1 | tr -d '[]')]  Server = $PAGES/$LINE/$VERSION"
if ! pacman -Sy --noconfirm > "$W/update.log" 2>&1; then
  echo "  !! pacman -Sy refused the database:"; sed 's/^/    /' "$W/update.log"; exit 1
fi
grep -iE "$REPO|qmdmm|error|warning" "$W/update.log" | sed 's/^/    /' || true

mapfile -t found < <(pacman -Sl "$REPO" 2>/dev/null | awk '{print $2}' | sort -u || true)
echo "  packages the database serves: ${found[*]:-<none>}"
[ "${#found[@]}" -ge 1 ] || { echo "  !! the source served no qmdmm package at all"; exit 1; }
if [ -n "$PKGS" ]; then
  assert_same_set "packages served vs built" "$(built_packages "$PKGS")" "$(printf '%s\n' "${found[@]}")"
fi

mapfile -t runtime < <(printf '%s\n' "${found[@]}" | runtime_packages)
[ "${#runtime[@]}" -ge 1 ] || { echo "  !! no runtime package to install"; exit 1; }
echo "  installing: ${runtime[*]}"
pacman -S --noconfirm "${runtime[@]}" > "$W/install.log" 2>&1 || {
  echo "  !! install failed:"; sed 's/^/    /' "$W/install.log"; exit 1; }
for p in "${runtime[@]}"; do
  pacman -Q "$p" | sed 's/^/  installed: /'
done
echo "  where pacman took it from:"
pacman -Qi "${runtime[0]}" | grep -iE '^(Version|Repository|Packager)' | sed 's/^/    /' || true

echo
echo "--- B) only the ROOT key locally signed -> must be refused ---"
pacman-key --lsign-key "$rootfpr" >/dev/null 2>&1 || true
pacman-key --delete "$sub" >/dev/null 2>&1 || true
rm -rf /var/lib/pacman/sync/*
if pacman -Sy --noconfirm > "$W/neg.log" 2>&1; then
  echo "  !! pacman accepted a database signed by a key it was not told to trust"
  sed 's/^/    /' "$W/neg.log"; exit 1
fi
echo "  OK: refused, as it must be"
grep -iE 'invalid or corrupted|unknown key|signature|error' "$W/neg.log" | head -4 | sed 's/^/    /' || true

echo
echo "=== B/pacman $LINE $VERSION: PASS ==="
