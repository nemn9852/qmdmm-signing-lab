#!/usr/bin/env bash
#
# When repo_gpgcheck is rejected on a fedora line, the first thing to ask is
# whether the *key* is even reaching dnf the way a real consumer would supply
# it. Every lab repo so far points gpgkey= at file:// because the key was just
# fetched to disk; a real consumer writes the published URL:
#
#     [qmdmm]
#     baseurl  = https://<pages>/<line>
#     gpgkey   = https://<pages>/keys/<line>/qmdmm-packages.gpg
#
# Those are different code paths, so run the same repo both ways and compare.
# This is a candidate *fix*, which is why it is worth its own probe: if https
# works where file:// fails, the fedora lines need no design change at all.
#
# Diagnostic: no `set -e`.
set -uo pipefail

PAGES="${LAB_PAGES:?}"
LINE="${LINE:?}"
W=/tmp/httpskey

echo "=== $LINE: does gpgkey= over https behave differently from file://? ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  rpm: $(rpm --version)   dnf: $(dnf --version | head -1)"
dnf install -y -q gnupg2 ca-certificates curl </dev/null >/dev/null 2>&1 || true

# shellcheck source=lib-site.sh
source /w/lab/lib-site.sh
wait_for_publish "$PAGES" "${EXPECT_SHA:?EXPECT_SHA not set}" || { echo "  !! site never came up"; exit 1; }

mkdir -p "$W"
echo
echo "--- fetch the published key (this is what a consumer would point at) ---"
for pair in "root:$PAGES/keys/qmdmm-root.gpg" "packages:$PAGES/keys/$LINE/qmdmm-packages.gpg"; do
  name="${pair%%:*}"; url="${pair##*:}"
  if curl -fsSL --max-time 30 "$url" -o "$W/$name.gpg"; then
    printf '    %-9s %s bytes\n' "$name" "$(wc -c < "$W/$name.gpg" | tr -d ' ')"
  else
    echo "    !! could not fetch $url"; exit 1
  fi
done

attempt() {
  local tag="$1" gpgkey="$2" d out
  d="$W/repo-$tag"; rm -rf "$d" "$W/cache-$tag"; mkdir -p "$d"
  cat > "$d/lab.repo" <<EOF
[lab]
name=lab $tag
baseurl=$PAGES/$LINE
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$gpgkey
EOF
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir="$W/cache-$tag" makecache 2>&1)
  printf '\n  --- %s\n' "$tag"
  printf '      gpgkey = %s\n' "$gpgkey"
  if echo "$out" | grep -qi 'signature verification error'; then
    printf '      verdict: REJECTED\n'
  else
    printf '      verdict: accepted\n'
  fi
  echo "$out" | grep -iE 'signature|not found|importing|public key|error' | head -4 | sed 's/^/      | /'
  local kr
  kr=$(find "$W/cache-$tag" -maxdepth 3 -type d -name 'pubring' 2>/dev/null | head -1)
  if [ -n "$kr" ]; then
    printf '      dnf keyring: %s\n' "$(ls -A "$kr" 2>/dev/null | tr '\n' ' ')"
  else
    printf '      dnf keyring: (none created)\n'
  fi
}

echo
echo "########## same repo, two ways of naming the key ##########"
attempt "file-url"  "file://$W/packages.gpg"
attempt "https-url" "$PAGES/keys/$LINE/qmdmm-packages.gpg"

echo
echo "=== read this as ==="
echo "  https accepted, file rejected -> the lab's file:// shortcut is the artefact;"
echo "                                   a real consumer is already fine"
echo "  both rejected                 -> it is the toolchain, not the key source"
