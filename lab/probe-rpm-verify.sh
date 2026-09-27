#!/usr/bin/env bash
#
# fedora:43 / rpm 6 / dnf5 imports our key into its per-repo keyring (a real
# 2825-byte <keyid>.pub file appears) and then still refuses the metadata with
# "Signing key not found". So the failure is on the verification side, not the
# import side. This probe isolates which property of the key/signature matters:
#
#   1. keyblock with a signing subkey, metadata signed by the SUBKEY
#   2. keyblock with a signing subkey, metadata signed by the PRIMARY
#   3. keyblock with NO subkey at all, metadata signed by the primary
#
# and prints, for each, what the signature itself advertises (issuer keyid vs
# issuer fingerprint) next to what dnf actually put in its keyring.
#
# Diagnostic: no `set -e`.
set -uo pipefail

LINE="${LINE:-rpm}"
ALGO="${ALGO:-ed25519}"
W=/tmp/verifydepth

echo "=== $LINE / $ALGO: what does dnf5 need to accept repomd.xml? ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  rpm: $(rpm --version)   dnf: $(dnf --version | head -1)   gpg: $(gpg --version | head -1)"
dnf install -y -q gnupg2 createrepo_c </dev/null >/dev/null 2>&1 || true

mkkey() {   # $1 = homedir, $2 = with-subkey|no-subkey
  local H="$1" kind="$2"
  rm -rf "$H"; mkdir -p "$H"; chmod 700 "$H"
  GNUPGHOME="$H" gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key "depth $kind <d@example.invalid>" "$ALGO" sign 0 >/dev/null 2>&1
  if [ "$kind" = with-subkey ]; then
    GNUPGHOME="$H" gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-add-key "$(fp "$H" primary)" "$ALGO" sign 0 >/dev/null 2>&1
  fi
}
fp() {      # $1 = homedir, $2 = primary|sub
  if [ "$2" = primary ]; then
    GNUPGHOME="$1" gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'
  else
    GNUPGHOME="$1" gpg --with-colons --list-secret-keys 2>/dev/null \
      | awk -F: '/^ssb:/{f=1;next} f&&/^fpr:/{print $10; f=0}' | tail -1
  fi
}

case_run() {  # $1 = tag, $2 = with-subkey|no-subkey, $3 = signer primary|sub
  local tag="$1" kind="$2" signer="$3"
  local H=$W/$tag/home
  local REPO=$W/$tag/repo
  mkkey "$H" "$kind"
  local ROOT SUB SIGNKEY
  ROOT=$(fp "$H" primary); SUB=$(fp "$H" sub)
  if [ "$signer" = sub ]; then SIGNKEY="$SUB"; else SIGNKEY="$ROOT"; fi

  mkdir -p "$REPO"
  GNUPGHOME="$H" createrepo_c "$REPO" >/dev/null 2>&1
  GNUPGHOME="$H" gpg --batch --yes --local-user "${SIGNKEY}!" --detach-sign --armor \
      -o "$REPO/repodata/repomd.xml.asc" "$REPO/repodata/repomd.xml" 2>/dev/null
  GNUPGHOME="$H" gpg --batch --export "$ROOT" > "$W/$tag/pub.gpg" 2>/dev/null

  printf '\n===== %s (keytype=%s, signer=%s)\n' "$tag" "$kind" "$signer"
  printf '      primary %s\n      subkey  %s\n' "$ROOT" "${SUB:-<none>}"
  printf '      signature issuer (what the .asc advertises):\n'
  GNUPGHOME="$H" gpg --list-packets "$REPO/repodata/repomd.xml.asc" 2>/dev/null \
    | grep -iE 'issuer|keyid|digest algo|pubkey algo' | sed 's/^/        /'
  printf '      subkey present in the exported .gpg? '
  GNUPGHOME=$W/$tag/probe-home bash -c "mkdir -p \$GNUPGHOME; chmod 700 \$GNUPGHOME; gpg --batch --import '$W/$tag/pub.gpg' >/dev/null 2>&1; gpg --with-colons --list-keys 2>/dev/null | awk -F: '/^sub:/{print \$5}'" \
    | tr '\n' ' ' | sed 's/^/[/;s/ $/]/'; echo

  local d=$W/$tag/repoconf
  mkdir -p "$d"
  cat > "$d/lab.repo" <<EOF
[lab]
name=lab $tag
baseurl=file://$REPO
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file://$W/$tag/pub.gpg
EOF

  local out
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir="$W/$tag/cache" makecache 2>&1)
  if echo "$out" | grep -qi 'signature verification error'; then
    printf '      verdict: SIGNATURE REJECTED\n'
  else
    printf '      verdict: accepted\n'
  fi
  echo "$out" | grep -iE 'signature|not found|importing|public key' | head -3 | sed 's/^/      | /'
  local kr
  kr=$(find "$W/$tag/cache" -maxdepth 3 -type d -name 'pubring' 2>/dev/null | head -1)
  if [ -n "$kr" ]; then
    printf '      dnf keyring contents: %s\n' "$(ls -A "$kr" 2>/dev/null | tr '\n' ' ')"
  else
    printf '      dnf keyring contents: (none)\n'
  fi
}

echo
echo "########## cases ##########"
case_run "withsub-sub-signs"    with-subkey sub
case_run "withsub-primary-signs" with-subkey primary
case_run "nosub-primary-signs"  no-subkey   primary

echo
echo "=== read this as ==="
echo "  only nosub passes        -> the subkey in the keyblock is the problem"
echo "  only *-primary-signs pass -> dnf5 looks up the SIGNING subkey, not the primary"
echo "  nothing passes            -> repo_gpgcheck is not usable on this rpm/dnf"
