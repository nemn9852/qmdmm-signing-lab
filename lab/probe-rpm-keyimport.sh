#!/usr/bin/env bash
#
# Follow-up to probe-rpm-signature.sh.
#
# That probe showed fedora:43 (rpm 6.0.2 / dnf5 5.2) reports "Signing key not
# found" for BOTH key types (ed25519, rsa4096) and for BOTH signers (subkey,
# primary) - while rocky:10 and alma:10 accept all four combinations. So this
# is not an algorithm or subkey issue at all: dnf5 is not obtaining the key
# from gpgkey= in the first place.
#
# This tries the obvious variations and dumps whatever the per-repo keyring
# ends up holding, so the next step is informed rather than guessed.
set -euo pipefail

LINE="${LINE:-rpm}"
W=/tmp/keyimport

echo "=== $LINE: how does dnf get the key? ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  rpm: $(rpm --version)"
echo "  dnf: $(dnf --version | head -1)"

dnf install -y -q gnupg2 rpm-sign createrepo_c </dev/null

export GNUPGHOME=$W/gnupghome
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
    'keyimport probe <ki@example.invalid>' ed25519 sign 0 2>&1 | tail -1 || true
ROOT=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
gpg --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$ROOT" ed25519 sign 0 2>&1 | tail -1 || true
SUB=$(gpg --with-colons --list-secret-keys "$ROOT" 2>/dev/null \
      | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
echo "  root = $ROOT"
echo "  sub  = $SUB"

REPO=$W/repo; mkdir -p "$REPO"
createrepo_c "$REPO" > /dev/null 2>&1
gpg --batch --yes --local-user "${SUB}!" --detach-sign --armor \
    -o "$REPO/repodata/repomd.xml.asc" "$REPO/repodata/repomd.xml"

gpg --batch --export "$ROOT" > "$W/pub.gpg"
gpg --batch --armor --export "$ROOT" > "$W/pub.asc"
echo "  pub.gpg $(wc -c < "$W/pub.gpg" | tr -d ' ')B   pub.asc $(wc -c < "$W/pub.asc" | tr -d ' ')B"

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
  [ "$preimport" = yes ] && rpm --import "$W/pub.gpg" >/dev/null 2>&1

  local out rc
  set +e
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir="$W/cache-$tag" makecache 2>&1)
  rc=$?
  set -e
  printf '  %-22s exit=%s  ' "$tag" "$rc"
  if echo "$out" | grep -qi 'signature verification error'; then echo "sig-error"; else echo "ok"; fi
  echo "$out" | grep -iE 'signature|not found|keyring|import' | head -2 | sed 's/^/      /' || true

  local kr
  kr=$(find "$W/cache-$tag" -maxdepth 2 -name 'pubring*' 2>/dev/null | head -1)
  if [ -n "$kr" ]; then
    echo "      keyring: $kr ($(wc -c < "$kr" | tr -d ' ')B)"
    gpg --no-default-keyring --keyring "$kr" --list-keys 2>/dev/null | sed 's/^/        /' || true
    gpg --no-default-keyring --keyring "$kr" --with-colons --list-keys 2>/dev/null \
      | awk -F: '/^(pub|sub|uid):/{printf "        %-4s %s\n", $1, ($1=="uid"?$10:$5)}' || true
  else
    echo "      keyring: (none created)"
  fi
  echo "      rpmdb keys: $(rpm -qa 'gpg-pubkey*' 2>/dev/null | tr '\n' ' ')"
}

echo
echo "=== variations ==="
attempt "binary-gpgkey"        "file://$W/pub.gpg" no
attempt "armored-gpgkey"       "file://$W/pub.asc" no
attempt "binary+rpm-import"    "file://$W/pub.gpg" yes
attempt "rpm-import-only"      "file:///nonexistent" yes

echo
echo "=== note what this means ==="
echo "  if only the rpm-import variants pass, dnf here ignores gpgkey= and needs"
echo "  the key in the global rpmdb - which would cost the per-repo scoping."
