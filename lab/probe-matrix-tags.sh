#!/usr/bin/env bash
#
# Issue #24 lists container tags as the release matrix. A tag that does not
# resolve is a red job on the first run for no reason - `rockylinux:10` was
# exactly that (the real name is rockylinux/rockylinux:10). Check them all at
# once, before the matrix is built on them.
#
# Uses `docker manifest inspect` so nothing is downloaded; falls back to a pull
# if that is unavailable.
set -uo pipefail

TAGS=(
  debian:trixie debian:forky debian:sid debian:latest
  ubuntu:resolute ubuntu:stonking
  fedora:44 fedora:45 fedora:rawhide
  rockylinux/rockylinux:10 almalinux:10
  archlinux:base manjarolinux/base:latest
  alpine:3.21 alpine:3.22 alpine:3.23 alpine:3.24 alpine:edge alpine:latest
)

echo "=== issue #24 container tags: do they resolve? ==="
printf '  docker: %s\n\n' "$(docker --version 2>/dev/null)"

ok=0; bad=0
for t in "${TAGS[@]}"; do
  if docker manifest inspect "$t" >/dev/null 2>&1; then
    printf '  OK       %s\n' "$t"; ok=$((ok+1)); continue
  fi
  if docker pull --quiet "$t" >/dev/null 2>&1; then
    printf '  OK(pull) %s\n' "$t"; ok=$((ok+1)); continue
  fi
  msg=$(docker manifest inspect "$t" 2>&1 | tail -1)
  printf '  MISSING  %-28s %s\n' "$t" "$msg"
  bad=$((bad+1))
done

echo
echo "  resolvable: $ok   missing: $bad"
echo
echo "=== note on the runner labels (not containers) ==="
echo "  macos-15 / macos-26 / macos-latest / xcode-27 cannot be probed from here;"
echo "  GitHub-hosted runner labels are not enumerable through the API."

# A check that cannot fail proves nothing. A missing tag here means a red job on
# the matrix's first real run, which is the thing this exists to prevent.
if [ "$bad" -gt 0 ]; then
  echo
  echo "!! $bad tag(s) do not resolve - fix issue #24 before building the matrix on them"
  exit 1
fi
echo
echo "all tags resolve"
