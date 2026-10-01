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
  # issue #24's container rows. `fedora:43` is struck through there and so is
  # absent here; it was also the row that already had a reason to go (a known
  # `yum` problem plus an upstream support window closing).
  #
  # `debian:latest` and `alpine:latest` are not #24's rows - they are the
  # floating tags packaging-smoke.yml builds against, listed because the two
  # workflows have to agree on what a line's images are.
  debian:trixie debian:forky debian:sid debian:latest
  ubuntu:resolute ubuntu:stonking
  fedora:44 fedora:45 fedora:rawhide
  rockylinux/rockylinux:10 almalinux:10
  archlinux:base manjarolinux/base:latest
  alpine:3.21 alpine:3.22 alpine:3.23 alpine:3.24 alpine:edge alpine:latest
)

echo "=== issue #24 container tags: do they resolve? ==="
printf '  docker: %s\n\n' "$(docker --version 2>/dev/null)"

# A check that cannot fail proves nothing. A check that could not *run* must not
# be allowed to look like one that failed, either: without a container runtime
# every tag below reports MISSING, the summary reads "19 missing", and that is
# indistinguishable from "issue #24 is wrong". This machine has no container
# runtime (docker/podman/skopeo/crane all absent) and no route to Docker Hub
# (tried both the hub and the registry API, 2026-10-01), so it cannot answer.
# Say so, and exit with a code that is not the one for a missing tag.
if ! command -v docker >/dev/null 2>&1; then
  cat <<'MSG'
  no container runtime here, and the registry API is not reachable from this
  machine either.

  => no reading was taken. This is NOT saying the tags are missing.

     Run this where a container runtime exists. If it cannot be run there
     either, the tags have to be confirmed by hand - and note that the matrix
     then rests on a by-hand answer rather than on this script.
MSG
  exit 2
fi

docker manifest inspect ubuntu:24.04 >/dev/null 2>&1 \
  || docker pull --quiet alpine:3 >/dev/null 2>&1 \
  || { echo "  the runtime is present but cannot reach a registry - no reading taken"; exit 2; }

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
