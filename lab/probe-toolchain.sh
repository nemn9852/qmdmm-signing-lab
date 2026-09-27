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
# Two questions, deliberately answered in order:
#
#   1. as shipped          - what stage A gets today, unchanged
#   2. with EL repos added - CRB and EPEL, for the Enterprise Linux rows only
#
# (2) exists because (1) fails on rockylinux/rockylinux:10 and succeeds on
# almalinux:10 with the same list. Reporting only (1) would say "rocky cannot
# build QMdmm", which is not true - it needs two repositories that
# base-image-rpm.sh does not enable. Both answers are printed.
#
#   env: FMT=deb|rpm|pac   (which pack-<fmt>.sh to read)
#        HARNESS=<path to the cloned QMdmmPackagingCI>
#
# Runs inside the distribution's own container. Exits non-zero when the row is
# not usable even after the prep step, so the matrix result is the answer.
set -uo pipefail

FMT="${FMT:?FMT=deb|rpm|pac}"
HARNESS="${HARNESS:-/w/harness}"
LAB="${LAB:-/w/lab}"

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

refresh_metadata() {
  case "$FMT" in
    deb) apt-get update -qq </dev/null >/dev/null 2>&1 || true ;;
    rpm) dnf -q -y makecache </dev/null >/dev/null 2>&1 || true ;;
    pac) echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
           > /etc/pacman.d/mirrorlist
         pacman -Sy --noconfirm --needed </dev/null >/dev/null 2>&1 || true ;;
  esac
}

# Fills MISSING with the names stage A cannot get right now.
check() {
  MISSING=''
  local out pkg
  case "$FMT" in
    deb)
      out=$(DEBIAN_FRONTEND=noninteractive apt-get install -s -y --no-install-recommends $LIST </dev/null 2>&1 || true)
      for pkg in $LIST; do
        if printf '%s' "$out" | grep -qE "Unable to locate package $pkg\b"; then
          printf '    MISSING  %s\n' "$pkg"; MISSING="$MISSING $pkg"
        else
          printf '    ok       %s\n' "$pkg"
        fi
      done
      printf '    qt6-base-dev candidate: %s\n' \
        "$(apt-cache policy qt6-base-dev 2>/dev/null | sed -n 's/^  Candidate: //p')"
      ;;
    rpm)
      out=$(dnf install --assumeno --setopt=install_weak_deps=False $LIST </dev/null 2>&1 || true)
      for pkg in $LIST; do
        if printf '%s' "$out" | grep -qE "No match for argument: $pkg\b|no package provides.*$pkg"; then
          printf '    MISSING  %s\n' "$pkg"; MISSING="$MISSING $pkg"
        else
          printf '    ok       %s\n' "$pkg"
        fi
      done
      printf '    qt6-qtbase-devel available: %s\n' \
        "$(dnf -q list --available qt6-qtbase-devel 2>/dev/null | tail -1)"
      ;;
    pac)
      for pkg in $LIST; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then
          printf '    ok       %s\n' "$pkg"
        else
          printf '    MISSING  %s\n' "$pkg"; MISSING="$MISSING $pkg"
        fi
      done
      printf '    qt6-base version: %s\n' \
        "$(pacman -Si qt6-base 2>/dev/null | sed -n 's/^Version *: *//p')"
      ;;
  esac
}

echo
echo "--- 1. as shipped (what stage A gets today) ---"
refresh_metadata
check

if [ -z "${MISSING// /}" ]; then
  echo
  echo "=== verdict ==="
  echo "  every package stage A asks for is available here, unchanged"
  exit 0
fi

if [ "$FMT" != rpm ]; then
  echo
  echo "=== verdict ==="
  echo "  !! stage A cannot run on this row - missing:$MISSING"
  exit 1
fi

echo
echo "--- 2. with CRB + EPEL enabled (EL rows) ---"
if [ -x "$LAB/el-prep.sh" ]; then
  bash "$LAB/el-prep.sh" 2>&1 | sed 's/^/  /'
else
  echo "  !! no $LAB/el-prep.sh"; exit 1
fi

echo
echo "--- re-check after enabling ---"
check

echo
echo "=== verdict ==="
if [ -z "${MISSING// /}" ]; then
  echo "  usable, but only after enabling CRB + EPEL."
  echo "  base-image-rpm.sh does not do this - finding for the harness."
  exit 0
fi
echo "  !! still cannot run on this row - missing:$MISSING"
exit 1
