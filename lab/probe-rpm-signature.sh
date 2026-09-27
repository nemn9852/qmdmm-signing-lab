#!/usr/bin/env bash
#
# One-off probe, run inside a dnf-based container:
# does THIS distro's rpm/dnf accept a repository-metadata signature made with
# key type $ALGO?
#
# Why: fedora:43 (rpm 6.0.2 / dnf5 5.2) rejected a repomd signed with an Ed25519
# *subkey*, while rocky:10 and alma:10 (rpm 4.19 / dnf 4.20) accepted the same
# thing. Before picking a key type for the real pipeline we need to know which
# of these it is:
#
#   A. subkey signed, $ALGO      -> the shape we actually want
#   B. primary signed, $ALGO     -> if A fails and B passes, it is a subkey
#                                   problem, not an algorithm problem
#
# env: LINE (label), ALGO (ed25519 | rsa4096)
set -euo pipefail

LINE="${LINE:-rpm}"
ALGO="${ALGO:-ed25519}"
W=/tmp/probe-$ALGO

echo "=== $LINE / $ALGO ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  rpm: $(rpm --version)"
echo "  dnf: $(dnf --version | head -1)"
echo "  gpg: $(gpg --version | head -1)"

dnf install -y -q gnupg2 rpm-sign createrepo_c </dev/null

export GNUPGHOME=$W/gnupghome
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

GEN="$ALGO"
case "$GEN" in ed25519|rsa4096) ;; *) echo "unsupported ALGO: $ALGO"; exit 1 ;; esac

echo
echo "=== generate a throwaway key ($ALGO) + one signing subkey ==="
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
    "probe $ALGO <probe@example.invalid>" "$GEN" sign 0 2>&1 | tail -2 || true
ROOT=$(gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
gpg --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$ROOT" "$GEN" sign 0 2>&1 | tail -1 || true
SUB=$(gpg --with-colons --list-secret-keys "$ROOT" 2>/dev/null \
      | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1)
echo "  root = $ROOT"
echo "  sub  = $SUB"
gpg --list-keys --keyid-format=long "$ROOT" 2>/dev/null | grep -E '^(pub|sub)' | sed 's/^/  /'

REPO=$W/repo
mkdir -p "$REPO"

try_sign() {
  local label="$1" key="$2" expect="$3"
  rm -rf "$REPO/repodata"
  createrepo_c "$REPO" > /dev/null 2>&1
  gpg --batch --yes --local-user "${key}!" --detach-sign --armor \
      -o "$REPO/repodata/repomd.xml.asc" "$REPO/repodata/repomd.xml" 2>/dev/null || {
    echo "  $label: could not sign at all"; return 1; }

  local d="$W/repos-$label"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/lab.repo" <<EOF
[lab]
name=probe $label
baseurl=file://$REPO
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file://$W/pub.gpg
EOF
  rm -rf /var/cache/dnf /tmp/dnfcache-$label
  local out rc verr
  set +e
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir=/tmp/dnfcache-$label makecache 2>&1)
  rc=$?
  set -e
  verr=0
  echo "$out" | grep -qi 'signature verification error' && verr=1
  echo "  $label: exit=$rc  sig-error=$verr  (expect $expect)"
  echo "$out" | grep -iE 'signature|error' | head -3 | sed 's/^/      /' || true
  find /tmp/dnfcache-$label -maxdepth 2 -name 'pubring*' 2>/dev/null | sed 's/^/      keyring: /' || true
}

echo
echo "=== export the public key (root + subkey) for the repo to use ==="
gpg --batch --export "$ROOT" > "$W/pub.gpg"
echo "  pub.gpg $(wc -c < "$W/pub.gpg" | tr -d ' ') bytes"

echo
echo "=== A: metadata signed by the SUBKEY ($ALGO) ==="
try_sign "subkey" "$SUB" "PASS if this distro accepts subkey signatures"

echo
echo "=== B: metadata signed by the PRIMARY key ($ALGO) ==="
try_sign "primary" "$ROOT" "PASS if the algorithm is fine and only subkeys are the problem"

echo
echo "=== verdict ==="
echo "  compare A and B above: A fail + B pass => subkeys are the problem, not $ALGO"
