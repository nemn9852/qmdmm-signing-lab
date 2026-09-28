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
  for i in $(seq 1 120); do
    # Twenty minutes, and both defences are needed. Pages is served through a
    # CDN, and a repeated request can keep answering with the previous deploy
    # long after the branch has moved - two cells of one run waited fifteen
    # minutes for a publish that other cells in the same run were already
    # reading. A cache-buster alone did not fix it, so no-cache headers are
    # asked for as well.
    #
    # curl exits 22 on an HTTP error; under `set -e` that would kill the script,
    # so swallow it and treat "no answer" as "not yet".
    raw=$(curl -fsSL --max-time 15 \
                -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                "$pages/publish.json?cb=${RANDOM}${RANDOM}" 2>&1 || true)
    got=$(printf '%s' "$raw" | tr -d ' \n' | sed -n 's/.*"sha":"\([0-9a-f]*\)".*/\1/p')
    if [ "$got" = "$expect" ]; then
      echo "  site is live at ${got:0:7} (waited ${i} poll(s))"
      return 0
    fi
    # What came back matters, and the first attempt is where to say it. "nothing"
    # can mean a deploy that has not landed yet, or a request that never got off
    # the ground - no CA bundle in the container, no resolver - and sitting out
    # fifteen minutes on the second one is not patience, it is a wrong diagnosis.
    if [ "$i" = 1 ]; then
      echo "  first attempt returned: $(printf '%s' "$raw" | head -c 200)"
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
#
# The `\n` in the format strings is load-bearing. `--qf '%{name}'` is applied to
# each package in turn, so without a newline every name is concatenated into one
# long word - "qmdmm-6qmdmm-6-develqmdmm-common-develqmdmm-doc" - which then
# fails a comparison against the built package list for a reason that looks like
# a repository problem and is a missing escape.
dnf_packages() {  # dnf_packages <repo-id> <workdir>
  local repo="$1" w="$2" out="" f
  out=$(dnf -y -q repoquery --repo="$repo" --qf '%{name}\n' 2>"$w/q1.err") || true
  if [ -z "$out" ]; then
    out=$(dnf -y -q repoquery --repo="$repo" --queryformat '%{name}\n' 2>"$w/q2.err") || true
  fi
  if [ -z "$out" ]; then
    out=$(dnf -y -q list --available --repo="$repo" 2>"$w/q3.err" \
          | awk 'NF>=3 {print $1}' | sed 's/\.[^.]*$//' | grep -v '^$' | sort -u) || true
  fi
  if [ -z "$out" ]; then
    # On stderr, and that matters: the callers capture stdout to get the package
    # list, so an explanation written to stdout becomes a "package name" and the
    # failure is then reported as "dnf still lists <the explanation> from the
    # tampered repository" - the exact opposite of what happened.
    {
      echo "  --- none of the three ways of listing this repository returned anything ---"
      for f in "$w"/q1.err "$w"/q2.err "$w"/q3.err; do
        if [ -s "$f" ]; then echo "    $(basename "$f"):"; sed 's/^/      /' "$f"; fi
      done
    } >&2
    return 1
  fi
  # Normalised to one name per line whatever separator dnf picked. `--qf` is
  # applied to each package in turn, so whether the names come out newline-
  # separated depends on the format string being honoured - and on the observed
  # behaviour of one line they did not, arriving space-separated instead. Asking
  # the question in terms of whitespace makes the answer independent of that.
  printf '%s\n' "$out" | tr -s '[:space:]' '\n' | grep -v '^$'
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

# Every fetch in these scripts is https, and a container with no CA bundle fails
# all of them. That failure surfaces far away - as "the site never served ...",
# fifteen minutes later, reading like a deploy problem - so it gets asked about
# directly, once, right after the tooling is installed.
assert_tls() {  # assert_tls <url>
  if ! curl -fsSL --max-time 20 -o /dev/null "$1?cb=cacert"; then
    echo "  !! curl cannot complete a TLS request to $1"
    echo "     (a container without a CA bundle looks exactly like this)"
    return 1
  fi
  echo "  curl reaches the site over TLS: yes"
}

# Install the tools a pacman-based row needs - and only the ones that are
# missing.
#
# On a rolling release, re-installing something already present can drag in a
# partial upgrade. Manjaro's base image carries a working curl; asking for it
# again pulled a libcurl built against a newer ngtcp2 than the image had, after
# which every https request died with
#
#   curl: symbol lookup error: /usr/lib/libcurl.so.4: undefined symbol:
#   ngtcp2_conn_get_tls_early_data_rejected2
#
# which names a library and presents itself as "the deploy never arrived".
# A rolling release is upgraded whole or not at all, so the safe move is not to
# touch what is there.
pacman_tools() {
  local p
  for p in gnupg curl ca-certificates; do
    if pacman -Q "$p" >/dev/null 2>&1; then
      echo "  $p already present"
      continue
    fi
    echo "  installing $p"
    if [ "$p" = curl ]; then
      # curl arrives with a library stack behind it. If it really is missing,
      # bring the system along rather than installing into a partial one.
      pacman -Syu --noconfirm --needed curl >/dev/null 2>&1 || true
    else
      pacman -Sy --noconfirm --needed "$p" >/dev/null 2>&1 \
        || pacman -Sy --noconfirm --needed ca-certificates-mozilla >/dev/null 2>&1 || true
    fi
  done
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
#
# "First" is only the right answer while a line has never been rotated. Use
# live_sub_fpr below for anything that hands the fingerprint to a tool.
first_sub_fpr() {  # first_sub_fpr <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^sub:/{f=1;next} f&&/^fpr:/{print $10; exit}'
}

# The fingerprint of the first subkey that can actually sign - i.e. not revoked,
# expired, disabled or invalid - or nothing if there is none.
#
# Why this exists: a rotated line's key file is
#     root + outgoing[revoked] + incoming
# and gpg lists the subkeys in that order, so `first_sub_fpr` returns the
# REVOKED one. Handing that to `pacman-key --lsign-key` locally signs a key that
# can no longer sign anything, and the database - signed by the incoming subkey
# - is then refused. From the outside that is a consumer cell going red on the
# day a line was rotated, which is the day nobody wants to debug the harness.
# (The debian line has carried a revoked subkey since its first rotation; it is
# only invisible because no apt cell ever asks "which subkey".)
#
# gpg's `--with-colons` validity field is one of u/i/d/r/e/o/q/n/-; anything but
# revoked/expired/disabled/invalid is usable.
live_sub_fpr() {  # live_sub_fpr <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f){if(s !~ /^[redi]$/){print $10; exit} f=0}}'
}

# How many subkeys a key file carries in a non-usable state - which for this lab
# is "how many times this line has been rotated".
dead_subkeys() {  # dead_subkeys <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^sub:/{if ($2 ~ /^[redi]$/) n++} END{print n+0}'
}

# The fingerprint of the first subkey that is NOT usable - for a line that has
# been rotated, the outgoing subkey. Paired with live_sub_fpr it is what makes
# "these two key files are two states of one line" an assertion rather than a
# hope: the revoked subkey in the refreshed file must BE the live subkey of the
# un-refreshed one.
dead_sub_fpr() {  # dead_sub_fpr <file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f){if(s ~ /^[redi]$/){print $10; exit} f=0}}'
}

# fetch_row_metadata <base-url> <fmt> <dest-dir>
#
# Take down one published repository's metadata only - no packages. Used both by
# stage C (which tampers with a copy of a published repository) and by the
# rotation tool (which freezes a repository as it was immediately before a line's
# key was rotated). Both want the same thing and neither wants the packages, so
# the repodata filename hashes are read out of repomd.xml rather than guessed.
fetch_row_metadata() {
  local base="$1" fmt="$2" r="$3" d f
  # The destination directory is created here for every format, not inside the
  # branches: the pacman one used to assume the caller had made it, and curl
  # reports a missing parent as "Failure writing output to destination ...
  # returned 4294967295", which names neither the file nor the directory.
  mkdir -p "$r"
  case "$fmt" in
    deb)
      d="$r/dists/$VERSION"
      mkdir -p "$d/main/binary-all"
      fetch "$base/dists/$VERSION/InRelease"                   "$d/InRelease"
      fetch "$base/dists/$VERSION/Release"                     "$d/Release"
      fetch "$base/dists/$VERSION/main/binary-all/Packages"    "$d/main/binary-all/Packages"
      fetch "$base/dists/$VERSION/main/binary-all/Packages.gz" "$d/main/binary-all/Packages.gz"
      ;;
    rpm)
      mkdir -p "$r/repodata"
      fetch "$base/repodata/repomd.xml"     "$r/repodata/repomd.xml"
      fetch "$base/repodata/repomd.xml.asc" "$r/repodata/repomd.xml.asc"
      # The rest of repodata is named with a hash, so it is read out of
      # repomd.xml instead of being guessed.
      local -a more=()
      mapfile -t more < <(grep -o 'href="repodata/[^"]*"' "$r/repodata/repomd.xml" \
                          | sed 's/^href="//; s/"$//' | sort -u)
      [ "${#more[@]}" -ge 1 ] || { echo "  !! repomd.xml names no other metadata file"; return 1; }
      for f in "${more[@]}"; do fetch "$base/$f" "$r/$f"; done
      ;;
    pac)
      fetch "$base/lab.db"     "$r/lab.db"
      fetch "$base/lab.db.sig" "$r/lab.db.sig"
      ;;
    *) echo "  !! no metadata layout known for format '$fmt'"; return 1 ;;
  esac
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
