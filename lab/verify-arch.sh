#!/usr/bin/env bash
#
# Consumer-side check, run inside a clean archlinux:base container.
# Public keys are fetched from Pages only - this job holds no secret at all.
#
# This line is the *negative* example: pacman keeps trusted keys in one global
# keyring and has no per-repository trust scope, so "who may sign this repo" is
# decided by "which keys were locally signed into the global keyring" - not by
# the repo stanza. Demonstrated by resetting the keyring between scenarios:
#
#   A. import this line's subkey + lsign -> pacman -Sy PASSES
#   B. import only the root key + lsign  -> pacman -Sy FAILS
#
# Consequence: on pacman the trust root cannot be protected by repo config.
# The keyring package has to be distributed out of band (ArchWiki unofficial
# keys route: download, check the fingerprint, pacman-key --add + --lsign-key).
set -euo pipefail

PAGES="${LAB_PAGES:?}"
ROOT_FPR="${ROOT_FPR:?}"
LINE="${LINE:-arch}"
W=/w/verify-arch

echo "=== environment ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "=== dependencies ==="
if ! grep -qE '^[[:space:]]*Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
pacman -Sy --noconfirm --needed gnupg ca-certificates curl > /tmp/pi.log 2>&1 </dev/null \
  || { tail -20 /tmp/pi.log; exit 1; }

fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsSL --max-time 30 "$url" -o "$out" && return 0
    echo "    fetch $url failed (attempt $i), retrying in 5s"; sleep 5
  done
  echo "    !! giving up: $url"; return 1
}

echo
echo "=== wait for this publish to be live (branch deploys are async) ==="
# shellcheck source=lib-site.sh
source /w/lab/lib-site.sh
wait_for_publish "$PAGES" "${EXPECT_SHA:?EXPECT_SHA not set}"

echo
echo "=== fetch public keys from Pages ==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"          "$W/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/packages.gpg"
for f in "$W/root.gpg" "$W/packages.gpg"; do
  printf '  %-14s ' "$(basename "$f")"
  gpg --with-colons --import-options show-only --import "$f" 2>/dev/null \
    | awk -F: '/^pub:/{p+=1} /^sub:/{s+=1} END{printf "pub=%d sub=%d\n", p+0, s+0}'
done

write_conf() {
  cat > /tmp/pacman-lab.conf <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseRequired
LocalFileSigLevel = Optional

[lab]
SigLevel = Required DatabaseRequired
Server = $PAGES/$LINE
EOF
}

reset_keyring() {
  rm -rf /etc/pacman.d/gnupg /var/lib/pacman/sync/*
  mkdir -p /etc/pacman.d/gnupg
  pacman-key --init > /tmp/pk-init.log 2>&1 || { tail -10 /tmp/pk-init.log; return 1; }
}

run_scenario() {
  local name="$1" keyfile="$2" expect="$3" out rc lfpr
  printf '\n--- %s (import %s, expect %s)\n' "$name" "$(basename "$keyfile")" "$expect"
  reset_keyring
  pacman-key --add "$keyfile" > /dev/null 2>&1
  # lsign the key this file actually carries (its subkey if it has one)
  lfpr=$(gpg --with-colons --import-options show-only --import "$keyfile" 2>/dev/null \
         | awk -F: '$1=="sub"{s=$5} $1=="pub"{p=$5} END{print (s ? s : p)}')
  echo "    lsigning key $lfpr"
  pacman-key --lsign-key "$lfpr" > /dev/null 2>&1
  write_conf
  set +e
  out=$(pacman -Sy --config /tmp/pacman-lab.conf --noconfirm 2>&1)
  rc=$?
  set -e
  echo "$out" | tail -6 | sed 's/^/    /'
  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ]; then echo "    => PASS"
    else echo "    => FAIL (expected PASS, got rc=$rc)"; return 1; fi
  else
    if [ $rc -ne 0 ]; then echo "    => REJECTED (rc=$rc)"
    else echo "    => FAIL (expected rejection, but it was accepted)"; return 1; fi
  fi
}

echo
echo "=============================================================="
echo "  pacman: trust is per-key-in-the-global-keyring, not per-repo"
echo "=============================================================="
run_scenario "A. import this line's subkey + lsign" "$W/packages.gpg" PASS
run_scenario "B. import only the root key + lsign"  "$W/root.gpg"     FAIL

echo
echo "=============================================================="
echo "  pacman has no per-repo trust scope: the repo stanza does not"
echo "  decide who may sign it, the global keyring does."
echo "  => the keyring package must be distributed out of band."
echo "=============================================================="
