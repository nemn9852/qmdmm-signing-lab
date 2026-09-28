#!/usr/bin/env bash
#
# Stage B for the trust bootstrap: install the keyring PACKAGE, and check that a
# user ends up with both repositories configured and trusted.
#
# The lab checks the keyring *source*'s signature in stage-b-keyring. This cell is
# the other half, and it is the one an actual user experiences: that source ships
# exactly one package, `qmdmm-archive-keyring`, and installing it is supposed to
# leave two working sources behind. Nothing else in CI installs it, so without
# this cell the claim "install the package and you are set up" has no witness at
# all (FINDINGS 10.8).
#
#   env: PAGES, ROOT_FPR, EXPECT_SHA
#
# What is checked:
#   A. holding only the ROOT key, the keyring source is readable and its package
#      installs - the one bootstrap step a user does by hand
#   B. the package brings BOTH sources with it, each naming its own key file
#   C. with the hand-made source removed, both sources still refresh on nothing
#      but the package's own configuration, and a package can be installed from
#      the day-to-day one
#
# C is the point of the cell. A keyring package that installs but configures
# nothing is indistinguishable from a working one, right up to the moment a user
# tries to use it.
set -euo pipefail

PAGES="${PAGES:?}"; ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
KEYDIR=/etc/apt/keyrings
mkdir -p "$KEYDIR" "$W/none"
source "$(dirname "$0")/lib-site.sh"

SRC=/etc/apt/sources.list.d/qmdmm-manual.list
PKG=qmdmm-archive-keyring

echo "=== B/install-keyring-package ==="
echo "  $(os_name)"

echo
echo "--- tooling ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq </dev/null
apt-get install -y -qq --no-install-recommends gnupg curl ca-certificates </dev/null
assert_tls "$PAGES/publish.json" || exit 1

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- keys, from Pages only ---"
fetch "$PAGES/keys/qmdmm-root.gpg"           "$KEYDIR/root.gpg"
fetch "$PAGES/keys/debian/qmdmm-packages.gpg" "$KEYDIR/packages.gpg"
chmod 644 "$KEYDIR"/root.gpg "$KEYDIR"/packages.gpg
[ "$(key_fpr "$KEYDIR/root.gpg")" = "$ROOT_FPR" ] \
  || { echo "  !! the root key file is not $ROOT_FPR"; exit 1; }

echo
echo "--- A) the one manual step: read the keyring source under the ROOT key ---"
# This is all a user does by hand, and the whole reason the keyring source exists
# as a separate repository: it is the one thing only the root key may sign.
echo "deb [signed-by=$KEYDIR/root.gpg] $PAGES/debian-keyring sid main" > "$SRC"
cat "$SRC" | sed 's/^/  | /'
if ! apt-get update -o Dir::Etc::sourcelist="$SRC" -o Dir::Etc::sourceparts="$W/none" \
       > "$W/a.log" 2>&1; then
  echo "  !! apt-get update refused the keyring source:"; sed 's/^/    /' "$W/a.log"; exit 1
fi
found=$(apt-cache search --names-only "^$PKG" | cut -d' ' -f1 | sort -u)
echo "  the keyring source offers: ${found:-<nothing>}"
[ "$found" = "$PKG" ] || { echo "  !! the keyring source does not offer $PKG"; exit 1; }

echo
echo "--- install it ---"
if ! apt-get install -y -qq --no-install-recommends "$PKG" > "$W/install.log" 2>&1; then
  echo "  !! installing $PKG failed:"; sed 's/^/    /' "$W/install.log"; exit 1
fi
dpkg-query -W -f='  installed: ${Package} ${Version} (${Status})\n' "$PKG"

echo
echo "--- B) what the package actually put on disk ---"
dpkg -L "$PKG" | sed 's/^/    /'
SOURCES=/etc/apt/sources.list.d/qmdmm.sources
[ -f "$SOURCES" ] || { echo "  !! $PKG did not install $SOURCES"; exit 1; }
echo "  --- $SOURCES ---"
sed 's/^/    /' "$SOURCES"
uris=$(grep -c '^URIs:' "$SOURCES")
signed=$(grep -c '^Signed-By:' "$SOURCES")
echo "  sources: $uris   Signed-By lines: $signed"
[ "$uris" = 2 ] || { echo "  !! expected both sources in the package, found $uris"; exit 1; }
[ "$signed" = 2 ] || { echo "  !! each source must name its own key file"; exit 1; }
grep -q 'qmdmm-root.gpg' "$SOURCES"     || { echo "  !! no source names the root key file"; exit 1; }
grep -q 'qmdmm-packages.gpg' "$SOURCES" || { echo "  !! no source names the line's key file"; exit 1; }
for f in /usr/share/keyrings/qmdmm-root.gpg /usr/share/keyrings/qmdmm-packages.gpg; do
  [ -f "$f" ] || { echo "  !! $PKG did not ship $f"; exit 1; }
  printf '    %s  (%s bytes, mode %s)\n' "$f" "$(wc -c < "$f" | tr -d ' ')" \
         "$(stat -c '%a' "$f")"
done

echo
echo "--- C) drop the hand-made source: everything must come from the package now ---"
rm -f "$SRC"
rm -rf /var/lib/apt/lists/*
if ! apt-get update > "$W/c.log" 2>&1; then
  echo "  !! with only the package's configuration, apt-get update fails:"
  sed 's/^/    /' "$W/c.log"; exit 1
fi
grep -i qmdmm "$W/c.log" | sed 's/^/    /' || true
for u in "debian-keyring" "debian/sid"; do
  grep -q "$u" "$W/c.log" || { echo "  !! nothing was fetched from $u"; exit 1; }
done

echo
echo "--- and a package can be installed from the day-to-day source ---"
runtime=$(apt-cache search --names-only '^qmdmm' | cut -d' ' -f1 | sort -u \
          | grep -v "^$PKG$" | runtime_packages)
[ -n "$runtime" ] || { echo "  !! no runtime package available from the day-to-day source"; exit 1; }
echo "  installing: $(printf '%s' "$runtime" | tr '\n' ' ')"
if ! apt-get install -y -qq --no-install-recommends $runtime > "$W/install2.log" 2>&1; then
  echo "  !! install from the day-to-day source failed:"; sed 's/^/    /' "$W/install2.log"
  exit 1
fi
for p in $runtime; do
  printf '  installed: %-22s %s\n' "$p" "$(dpkg-query -W -f='${Version} (${Status})' "$p")"
done

echo
echo "=== B/install-keyring-package: PASS ==="
