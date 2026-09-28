#!/usr/bin/env bash
#
# Stage B for the deb format: the **apt** consumer.
#
# Named by consumer on purpose. deb is the package format; apt is the program
# that reads it. Stage S produced a signed repository at format level, and this
# script is what asks whether a real consumer can use it - nothing below may
# state a deb-shaped fact that is really an apt behaviour.
#
# It runs inside a clean Debian/Ubuntu container, takes its public keys from
# Pages and nowhere else, and holds no secret at all: this is a consumer's
# exact position, not a rehearsal of it.
#
#   env: PAGES      site root
#        LINE       distribution line, e.g. debian
#        VERSION    apt suite, e.g. trixie
#        ROOT_FPR   the root key's fingerprint, to check what was downloaded
#        EXPECT_SHA the publish this consumer insists on seeing
#        PKGS       optional: stage A's out/ dir, for the "served == built" check
#
# What is checked:
#   A. day-to-day source + this line's public key   -> must PASS, and install
#   B. same source + the ROOT public key only       -> must FAIL
#
# B is the sharper half, and the reason the subkey design exists at all: the
# day-to-day source is signed by the line's subkey, so a consumer holding only
# the root key must not be able to accept it. If A and B both passed, the
# subkey would be decoration.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
PKGS="${PKGS:-}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/keys" /etc/apt/sources.list.d
source "$(dirname "$0")/lib-site.sh"

echo "=== B/apt $LINE $VERSION ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  apt: $(apt-get --version | head -1)"

echo
echo "--- tooling ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null
apt-get install -y -qq --no-install-recommends gnupg curl ca-certificates </dev/null
echo "  gnupg $(gpg --version | head -1 | sed 's/^gpg (GnuPG) //')"

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
echo "  root key file:   $rootfpr   subkeys: $nsub"
[ "$rootfpr" = "$ROOT_FPR" ] || { echo "  !! root fingerprint is not $ROOT_FPR"; exit 1; }
[ "$nsub" = 0 ] || { echo "  !! the root key file carries subkeys; it must carry none"; exit 1; }
sub=$(first_sub_fpr "$W/keys/packages.gpg")
echo "  packages key:    $sub   (this line's operational subkey)"
[ -n "$sub" ] || { echo "  !! the packages key file carries no subkey"; exit 1; }
[ "$sub" != "$rootfpr" ] || { echo "  !! the packages key file's subkey IS the root key"; exit 1; }
echo "  OK: root and operational keys are different keys"

echo
echo "--- A) the day-to-day source, signed by this line's subkey ---"
src="$W/qmdmm.list"
echo "deb [signed-by=$W/keys/packages.gpg] $PAGES/$LINE/$VERSION $VERSION main" > "$src"
cat "$src" | sed 's/^/  | /'
if ! apt-get update -o Dir::Etc::sourcelist="$src" -o Dir::Etc::sourceparts=/dev/null \
        -o APT::Get::List-Cleanup=0 > "$W/update.log" 2>&1; then
  echo "  !! apt-get update refused the source:"; sed 's/^/    /' "$W/update.log"; exit 1
fi
grep -i qmdmm "$W/update.log" | sed 's/^/    /' || true

found=$(apt-cache search --names-only '^qmdmm' | cut -d' ' -f1 | sort -u)
echo "  packages the repository serves: $(printf '%s' "$found" | tr '\n' ' ')"
[ -n "$found" ] || { echo "  !! the source served no qmdmm package at all"; exit 1; }
if [ -n "$PKGS" ]; then
  assert_same_set "packages served vs built" "$(built_packages "$PKGS")" "$found"
fi

runtime=$(printf '%s\n' "$found" | runtime_packages)
[ -n "$runtime" ] || { echo "  !! no runtime package to install"; exit 1; }
echo "  installing: $(printf '%s' "$runtime" | tr '\n' ' ')"
apt-get install -y -qq --no-install-recommends $runtime > "$W/install.log" 2>&1 || {
  echo "  !! install failed:"; sed 's/^/    /' "$W/install.log"; exit 1; }
for p in $runtime; do
  printf '  installed: %-22s %s\n' "$p" "$(dpkg-query -W -f='${Version} (${Status})' "$p")"
done
echo "  where apt took it from:"
apt-cache policy $runtime | grep -A1 -E '^\S' | sed 's/^/    /' | head -12

echo
echo "--- B) the same source with the ROOT key only -> must be refused ---"
neg="$W/qmdmm-root-only.list"
echo "deb [signed-by=$W/keys/root.gpg] $PAGES/$LINE/$VERSION $VERSION main" > "$neg"
rm -rf /var/lib/apt/lists/*
if apt-get update -o Dir::Etc::sourcelist="$neg" -o Dir::Etc::sourceparts=/dev/null \
       > "$W/neg.log" 2>&1; then
  echo "  !! apt accepted a source signed by a subkey while holding only the root key"
  sed 's/^/    /' "$W/neg.log"; exit 1
fi
echo "  OK: refused, as it must be"
grep -iE 'no_pubkey|is not signed|public key|NO_PUBKEY|missing' "$W/neg.log" | head -4 | sed 's/^/    /' || true

echo
echo "=== B/apt $LINE $VERSION: PASS ==="
