#!/usr/bin/env bash
#
# Can this row actually build QMdmm?
#
# Stage A installs a Qt 6 development toolchain per line, and three of the rows
# in the matrix are images for *unreleased* distributions (debian:forky,
# ubuntu:resolute, ubuntu:stonking). If their archives have no qt6 packages
# there is no point discovering that from a 12-row build; ask directly.
#
# The package list is not copied here. It is read out of the harness's own
# pack-<fmt>.sh, so this can never disagree with what stage A will ask for.
#
#   env: FMT=deb|rpm|pac   (which pack-<fmt>.sh to read)
#        HARNESS=<path to the cloned QMdmmPackagingCI>
#
# Runs inside the distribution's own container. Exits non-zero when anything
# stage A needs is missing, so the matrix result is the answer per row.
set -euo pipefail

FMT="${FMT:?FMT=deb|rpm|pac}"
HARNESS="${HARNESS:-/w/harness}"

echo "=== $FMT: toolchain availability ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  uname: $(uname -m)"

# The list stage A installs, taken from stage A's own script.
LIST=$(awk -v fmt="$FMT" '
  $0 ~ "base-image-" fmt "\\.sh" { f = 1; next }
  f {
    line = $0; sub(/[[:space:]]*\\[[:space:]]*$/, "", line)
    printf "%s ", line
    if ($0 !~ /\\[[:space:]]*$/) exit
  }' "$HARNESS/ci/pack-$FMT.sh")
if [ -z "${LIST// /}" ]; then
  echo "  !! could not read the package list out of $HARNESS/ci/pack-$FMT.sh"; exit 1
fi
echo "  stage A will install: $LIST"

echo
echo "--- metadata refresh ---"
case "$FMT" in
  deb)
    apt-get update -qq </dev/null 2>&1 | tail -3 | sed 's/^/    /' || true
    ;;
  rpm)
    dnf -q -y makecache </dev/null 2>&1 | tail -3 | sed 's/^/    /' || true
    ;;
  pac)
    echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
      > /etc/pacman.d/mirrorlist
    pacman -Sy --noconfirm --needed </dev/null 2>&1 | tail -3 | sed 's/^/    /' || true
    ;;
esac

echo
echo "--- is each package available? (nothing is installed) ---"
missing=''
case "$FMT" in
  deb)
    out=$(DEBIAN_FRONTEND=noninteractive apt-get install -s -y --no-install-recommends $LIST </dev/null 2>&1 || true)
    while read -r pkg; do
      [ -n "$pkg" ] || continue
      if printf '%s' "$out" | grep -qE "Unable to locate package $pkg\b"; then
        printf '    MISSING  %s\n' "$pkg"; missing="$missing $pkg"
      else
        printf '    ok       %s\n' "$pkg"
      fi
    done <<< "$(printf '%s\n' $LIST | tr ' ' '\n')"
    echo
    printf '    qt6-base-dev candidate: %s\n' \
      "$(apt-cache policy qt6-base-dev 2>/dev/null | sed -n 's/^  Candidate: //p')"
    ;;
  rpm)
    out=$(dnf install --assumeno --setopt=install_weak_deps=False $LIST </dev/null 2>&1 || true)
    while read -r pkg; do
      [ -n "$pkg" ] || continue
      if printf '%s' "$out" | grep -qE "No match for argument: $pkg\b|no package provides.*$pkg"; then
        printf '    MISSING  %s\n' "$pkg"; missing="$missing $pkg"
      else
        printf '    ok       %s\n' "$pkg"
      fi
    done <<< "$(printf '%s\n' $LIST | tr ' ' '\n')"
    echo
    printf '    qt6-qtbase-devel available: %s\n' \
      "$(dnf -q list --available qt6-qtbase-devel 2>/dev/null | tail -1)"
    ;;
  pac)
    while read -r pkg; do
      [ -n "$pkg" ] || continue
      if pacman -Si "$pkg" >/dev/null 2>&1; then
        printf '    ok       %s\n' "$pkg"
      else
        printf '    MISSING  %s\n' "$pkg"; missing="$missing $pkg"
      fi
    done <<< "$(printf '%s\n' $LIST | tr ' ' '\n')"
    echo
    printf '    qt6-base version: %s\n' \
      "$(pacman -Si qt6-base 2>/dev/null | sed -n 's/^Version *: *//p')"
    ;;
esac

echo
echo "=== verdict ==="
if [ -n "$missing" ]; then
  echo "  !! stage A cannot run on this row - missing:$missing"
  exit 1
fi
echo "  every package stage A asks for is available here"
