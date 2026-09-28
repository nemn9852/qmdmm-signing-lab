#!/usr/bin/env bash
#
# Shared by the stage B consumer scripts and the stage C taint scripts.
#
# Why wait_for_publish exists: Pages serves the gh-pages branch, and publishing
# to a branch is asynchronous - the push returns immediately, the build and its
# CDN invalidation do not. A consumer that starts right after publish therefore
# reads the PREVIOUS site, which looks like a broken signature scheme rather
# than a stale deploy. (That is exactly what happened on the first run.)
#
# So publish drops a publish.json naming the commit it built, and every consumer
# waits for the site to actually serve that commit before asserting anything.

wait_for_publish() {
  local pages="$1" expect="$2" got="" raw="" i
  for i in $(seq 1 90); do
    # The cache-buster is not decoration. Pages is served through a CDN, and a
    # plain repeated request can keep answering with the previous deploy long
    # after the branch has moved - two cells of one run waited fifteen minutes
    # for a publish that other cells in the same run were already reading.
    # curl exits 22 on an HTTP error; under `set -e` that would kill the script,
    # so swallow it and treat "no answer" as "not yet".
    raw=$(curl -fsSL --max-time 15 "$pages/publish.json?cb=${RANDOM}${RANDOM}" 2>/dev/null || true)
    got=$(printf '%s' "$raw" | tr -d ' \n' | sed -n 's/.*"sha":"\([0-9a-f]*\)".*/\1/p')
    if [ "$got" = "$expect" ]; then
      echo "  site is live at ${got:0:7} (waited ${i} poll(s))"
      return 0
    fi
    echo "  waiting for the deploy to catch up (site currently serves: ${got:-nothing})"
    sleep 10
  done
  echo "  !! the site never served publish ${expect:0:7}"
  return 1
}

# List the package names a repository serves, across dnf4 and dnf5.
#
# Three shapes, tried in order, because the option that selects the output
# format was renamed between the two dnf generations - and a rejected option can
# still leave dnf printing its default NEVRA, which is not the same answer:
#
#   1. `repoquery --qf`           dnf4 spelling
#   2. `repoquery --queryformat`  dnf5 spelling
#   3. `list --available`         both, and its output shape has not moved
#
# Nothing here swallows the reason. If all three come back empty, each one's
# stderr is printed, because "this repository serves no package" and "the
# command never ran properly" look identical from the outside and only one of
# them is a finding. `-y` is on every call: dnf4 asks whether to import the
# repository's key, and with no stdin that answer becomes "no".
dnf_packages() {  # dnf_packages <repo-id> <workdir>
  local repo="$1" w="$2" out="" f
  out=$(dnf -y -q repoquery --repo="$repo" --qf '%{name}' 2>"$w/q1.err") || true
  if [ -z "$out" ]; then
    out=$(dnf -y -q repoquery --repo="$repo" --queryformat '%{name}' 2>"$w/q2.err") || true
  fi
  if [ -z "$out" ]; then
    out=$(dnf -y -q list --available --repo="$repo" 2>"$w/q3.err" \
          | awk 'NF>=3 {print $1}' | sed 's/\.[^.]*$//' | grep -v '^$' | sort -u) || true
  fi
  if [ -z "$out" ]; then
    echo "  --- none of the three ways of listing this repository returned anything ---"
    for f in "$w"/q1.err "$w"/q2.err "$w"/q3.err; do
      if [ -s "$f" ]; then echo "    $(basename "$f"):"; sed 's/^/      /' "$f"; fi
    done
    return 1
  fi
  printf '%s\n' "$out"
}

# The distribution's own name, for the log line.
#
# This deliberately does NOT source /etc/os-release. Sourcing it would define
# every variable that file happens to contain, and one of them is `VERSION` -
# which is also an input of these scripts. On fedora:45 that silently turned
# `VERSION=45` into `VERSION=45 (Container Image Prerelease)`, and the baseurl
# was built as `.../fedora/45 (Container Image Prerelease)`, so every consumer
# reported an empty repository. The trap is invisible until something that
# embeds the variable in a URL fails.
os_name() {
  local v
  v=$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -1)
  [ -n "$v" ] || v=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -1)
  printf '%s' "${v:-unknown}"
}

# fetch <url> <dest> - public material only, and it says so in the log, because
# "the consumer got its keys from Pages" is a claim this lab has to be able to
# point at.
fetch() {
  local url="$1" dest="$2" size
  if ! curl -fsSL --max-time 180 "$url" -o "$dest"; then
    echo "  !! could not fetch ${url#*/qmdmm-signing-lab/}"
    return 1
  fi
  size=$(wc -c < "$dest" | tr -d ' ')
  printf '  %-46s %8s bytes\n' "${url#*/qmdmm-signing-lab/}" "$size"
}

# The root fingerprint of a key file - the first ^fpr: after ^pub:.
key_fpr() {  # key_fpr <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^pub:/{f=1;next} f&&/^fpr:/{print $10; exit}'
}

# The fingerprint of the first signing subkey in a key file.
first_sub_fpr() {  # first_sub_fpr <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^sub:/{f=1;next} f&&/^fpr:/{print $10; exit}'
}

count_subkeys() {  # count_subkeys <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^sub:/{n++} END{print n+0}'
}

# The package names stage A recorded for this row. Empty when the artifact was
# not handed over, which turns the "served == built" assertion into a no-op
# rather than a false failure.
built_packages() {  # built_packages <pkgs-dir>
  local dir="${1:-}"
  if [ -n "$dir" ] && [ -f "$dir/MANIFEST.tsv" ]; then
    tail -n +2 "$dir/MANIFEST.tsv" | cut -f1 | sort -u
  fi
}

# The runtime packages out of a list - the ones a normal user installs. The
# -dev / -devel / -doc packages are asserted to exist, but installing them
# would only drag in a toolchain this check is not about.
runtime_packages() {
  grep -vE -- '-(dev|devel|doc)$' || true
}

# assert_same_set <label> <expected-newline-list> <got-newline-list>
assert_same_set() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "  !! $label differ"
    echo "     built:  $(printf '%s' "$want" | tr '\n' ' ')"
    echo "     served: $(printf '%s' "$got"  | tr '\n' ' ')"
    return 1
  fi
  echo "  $label match: $(printf '%s' "$want" | tr '\n' ' ')"
}
