#!/usr/bin/env bash
#
# Why does fedora:43 (rpm 6.0.2 / dnf5 5.2) reject repomd.xml signed by a key it
# was handed through gpgkey= ?  probe-rpm-signature.sh showed this is neither
# the key type (ed25519 and rsa4096 both fail) nor the subkey (primary-signed
# metadata fails too), while rocky:10 / alma:10 accept every combination.
#
# So: how does dnf get the key, and where does it put it?
#
#   A. binary gpgkey, no preimport
#   B. armored gpgkey, no preimport
#   C. binary gpgkey, plus rpm --import (key in the global rpmdb)
#   D. no gpgkey at all, plus rpm --import
#
# Diagnostic, so deliberately NOT `set -e`: a failure in one variation must not
# hide the remaining ones. Every step is guarded and every result is printed.
set -uo pipefail

LINE="${LINE:-rpm}"
W=/tmp/keyimport
A_TAG=""
FULLKEY=""

echo "=== $LINE: how does dnf obtain the key? ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  rpm: $(rpm --version)"
echo "  dnf: $(dnf --version | head -1)"
echo "  gpg: $(gpg --version | head -1)"

dnf install -y -q gnupg2 rpm-sign createrepo_c </dev/null >/dev/null 2>&1 || true

export GNUPGHOME=$W/gnupghome
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
    'keyimport probe <ki@example.invalid>' ed25519 sign 0 >/dev/null 2>&1
ROOT=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
gpg --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$ROOT" ed25519 sign 0 >/dev/null 2>&1
SUB=$(gpg --with-colons --list-secret-keys "$ROOT" 2>/dev/null \
      | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
echo "  root = $ROOT"
echo "  sub  = $SUB"

REPO=$W/repo; mkdir -p "$REPO"
createrepo_c "$REPO" >/dev/null 2>&1
gpg --batch --yes --local-user "${SUB}!" --detach-sign --armor \
    -o "$REPO/repodata/repomd.xml.asc" "$REPO/repodata/repomd.xml" 2>/dev/null

gpg --batch --export "$ROOT" > "$W/pub.gpg" 2>/dev/null
gpg --batch --armor --export "$ROOT" > "$W/pub.asc" 2>/dev/null
# the keyid dnf/rpm will talk about, for this container's key
KEYID_SHORT="${ROOT: -8}"
echo "  pub.gpg $(wc -c < "$W/pub.gpg" | tr -d ' ')B   pub.asc $(wc -c < "$W/pub.asc" | tr -d ' ')B   keyid 0x$KEYID_SHORT"

rpmdb_keys() { rpm -qa 'gpg-pubkey*' 2>/dev/null | tr '\n' ' '; }

attempt() {
  local tag="$1" gpgkey="$2" preimport="$3"
  local d=$W/repo-$tag
  rm -rf "$d" "$W/cache-$tag"; mkdir -p "$d"
  cat > "$d/lab.repo" <<EOF
[lab]
name=lab $tag
baseurl=file://$REPO
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=$gpgkey
EOF

  if [ "$preimport" = yes ]; then
    if rpm --import "$W/pub.gpg" >/dev/null 2>&1; then echo "  [$tag] rpm --import: ok"
    else echo "  [$tag] rpm --import: FAILED"; fi
  fi

  local out rc
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir="$W/cache-$tag" makecache 2>&1); rc=$?

  printf '\n  --- %-20s exit=%s\n' "$tag" "$rc"
  if echo "$out" | grep -qi 'signature verification error'; then
    printf '      verdict: SIGNATURE REJECTED\n'
  else
    printf '      verdict: accepted\n'
  fi
  echo "$out" | grep -iE 'signature|not found|importing|keyring|public key' | head -4 | sed 's/^/      | /'

  # dnf5 keeps its per-repo keyring under the cache dir; on dnf5 it can be a
  # keybox *directory*, so do not assume a regular file.
  local kr
  kr=$(find "$W/cache-$tag" -maxdepth 3 \( -name 'pubring*' -o -name 'pubring.kbx' \) 2>/dev/null | head -1)
  if [ -n "$kr" ]; then
    printf '      per-repo keyring: %s' "$kr"
    if [ -d "$kr" ]; then
      printf '  (directory, %s entries)\n' "$(ls -A "$kr" 2>/dev/null | wc -l | tr -d ' ')"
      ls -la "$kr" 2>/dev/null | sed -n '2,8p' | sed 's/^/        /'
    else
      printf '  (%s bytes)\n' "$(wc -c < "$kr" 2>/dev/null | tr -d ' ')"
      gpg --no-default-keyring --keyring "$kr" --with-colons --list-keys 2>/dev/null \
        | awk -F: '/^(pub|sub|uid):/{printf "        %-4s %s\n", $1, ($1=="uid"?$10:$5)}' || true
    fi
  else
    printf '      per-repo keyring: (none created)\n'
  fi

  printf '      rpmdb gpg-pubkey entries: %s\n' "$(rpmdb_keys)"
  printf '      our key in rpmdb? '
  if rpmdb_keys | grep -qi "${KEYID_SHORT}"; then echo "yes"; else echo "no"; fi
}

echo
echo "=== variations (this container's key ends 0x$KEYID_SHORT) ==="
attempt "binary-gpgkey"     "file://$W/pub.gpg" no
attempt "armored-gpgkey"    "file://$W/pub.asc" no
attempt "binary+rpm-import" "file://$W/pub.gpg" yes
attempt "rpm-import-only"   "file:///nonexistent" yes

echo
echo "=== read this as ==="
echo "  all four rejected   -> repo_gpgcheck on this rpm/dnf is unusable, whatever"
echo "                         the key type; fall back to gpgcheck (global rpmdb)"
echo "  only X passes       -> X is the contract this version actually honours"
