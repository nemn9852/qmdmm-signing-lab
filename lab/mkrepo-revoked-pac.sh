#!/usr/bin/env bash
#
# Build a tiny pacman repository whose database is signed by a key that HAS
# SINCE BEEN REVOKED. The pacman counterpart of `site/debian-revoked`, and the
# remaining format after the rpm one (FINDINGS 10.8).
#
# Same reasoning as the rpm fixture: the signature must be made before the
# revocation, the private half lives only in the `fixture` environment, and the
# two public states of that key are committed so one artifact can be shown to
# produce two verdicts.
#
# Unlike rpm, repo-add insists on at least one package, so a minimal one is
# assembled here - a .PKGINFO and a file, which is all a pacman package really
# is. It is never installed; it exists so that the database has an entry.
#
#   env: SIGNING_KEY_B64 - base64 of the pre-revocation secret-subkey export
#        OUT             - repository root to build
set -euo pipefail

OUT="${OUT:?}"; KEY_B64="${SIGNING_KEY_B64:-}"
[ -n "$KEY_B64" ] || { echo "!! no signing key supplied"; exit 1; }

echo "=== fixture: pacman repository signed by a since-revoked key ==="
# Not `. /etc/os-release` - see FINDINGS 3.10.
echo "  $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)"

echo
echo "--- tooling ---"
pacman -Sy --noconfirm --needed gnupg pacman-contrib zstd >/dev/null 2>&1 || true
echo "  repo-add: $(command -v repo-add || echo MISSING)"
echo "  zstd:     $(command -v zstd || echo MISSING)"

echo
echo "--- import the key (its pre-revocation private half) ---"
printf '%s\n' "$KEY_B64" | base64 -d | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
mapfile -t SUBS < <(gpg --with-colons --list-secret-keys 2>/dev/null \
                    | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}')
if [ "${#SUBS[@]}" -ne 1 ]; then
  echo "  !! expected exactly 1 usable subkey here, found ${#SUBS[@]}"; exit 1
fi
SUB="${SUBS[0]}"
echo "  signing subkey = $SUB"

echo
echo "--- prove this import can actually sign ---"
# See the rpm fixture: an import that already carries the revocation certificate
# is refused by gpg at signing time, and that would look like a broken fixture
# rather than the wrong export having been uploaded.
PROBE=$(mktemp); ERRF=$(mktemp)
if ! printf 'probe\n' | gpg --batch --yes --local-user "${SUB}!" --detach-sign \
       -o "$PROBE" 2>"$ERRF"; then
  echo "  !! this key cannot sign - is the pre-revocation export the one that was uploaded?"
  sed 's/^/    /' "$ERRF"
  rm -f "$PROBE" "$ERRF"; exit 1
fi
rm -f "$PROBE" "$ERRF"
echo "  OK: the imported key can sign"

echo
echo "--- assemble a minimal package (repo-add will not accept an empty database) ---"
mkdir -p "$OUT"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/pkg/usr/share/qmdmm-fixture"
echo "fixture for a revoked-key pacman repository" > "$WORK/pkg/usr/share/qmdmm-fixture/README"
cat > "$WORK/pkg/.PKGINFO" <<EOF
pkgname = qmdmm-fixture
pkgbase = qmdmm-fixture
pkgver = 1.0-1
pkgdesc = fixture package for a repository signed by a revoked key
url = https://example.invalid
builddate = $(date +%s)
packager = QMdmm signing lab <lab@example.invalid>
size = 0
arch = any
EOF
PKG="$OUT/qmdmm-fixture-1.0-1-any.pkg.tar.zst"
( cd "$WORK/pkg" && tar --zstd -cf "$PKG" .PKGINFO usr )
echo "  $PKG  ($(wc -c < "$PKG" | tr -d ' ') bytes)"

echo
echo "--- build the database and sign it with the revoked-later key ---"
cd "$OUT"
rm -f fixture.db* fixture.files*
repo-add -s -k "$SUB" fixture.db.tar.gz ./*.pkg.tar.zst 2>&1 | sed 's/^/  /'
[ -f fixture.db.tar.gz.sig ] || { echo "  !! no fixture.db.tar.gz.sig was produced"; exit 1; }

echo
echo "--- who signed it (must be the fixture key, and valid *now*) ---"
gpg --verify "$OUT/fixture.db.tar.gz.sig" "$OUT/fixture.db.tar.gz" 2>&1 | sed 's/^/    /'

echo
echo "--- output ---"
find "$OUT" -maxdepth 1 -type f | sort | sed 's/^/  /'
