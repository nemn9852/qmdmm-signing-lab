#!/usr/bin/env bash
#
# Enterprise Linux rows need two repositories that `base-image-rpm.sh` does not
# enable.
#
# Found by probing rather than by a failed build: on rockylinux/rockylinux:10,
# stage A's list is missing `ninja-build` and `doxygen`, while the same list on
# almalinux:10 is complete. The two EL rows are not interchangeable, and the fix
# for Rocky is not a different package name - it is two extra repositories.
#
#   ninja-build  lives in CRB (CodeReady Builder), disabled by default
#   doxygen      also came from CRB in the measurement below - EPEL is tried
#                too, but it is not what supplies either package here:
#
#     ninja-build   available: 1.11.1-9.el10   (crb)
#     doxygen       available: 2:1.13.2-1.el10 (crb)
#
# So the load-bearing change for Rocky is enabling CRB; EPEL is enabled as well
# (and reported) because a different EL rebuild may route it differently, but the
# evidence says CRB is the one that matters.
#
# So this enables CRB and EPEL, reports what changed, and re-answers the same
# question the probe asks. Fedora does not need it: everything is in the base
# repositories there, which is why only the EL rows call this.
#
# Runs inside the container. Never fatal on its own - the caller decides.
set -uo pipefail

echo "=== EL repository prep ==="
. /etc/os-release && echo "  $PRETTY_NAME"

echo
echo "--- repos before ---"
dnf -q repolist --all 2>/dev/null | awk '$2 == "enabled" { print "    " $1 }' | head -12

echo
echo "--- dnf-plugins-core (for config-manager) ---"
dnf install -y -q dnf-plugins-core </dev/null >/dev/null 2>&1 \
  && echo "    installed" || echo "    !! could not install"

echo
echo "--- enabling CRB ---"
# The repo id differs across EL rebuilds and versions, and an id that does not
# exist is not an error worth stopping for - each one is tried and reported.
for repo in crb powertools codeready-builder-for-rhel-10-x86_64-rpms \
            codeready-builder-for-rhel-9-x86_64-rpms; do
  if dnf -q repolist --all 2>/dev/null | awk '{print $1}' | grep -qx "$repo"; then
    if dnf config-manager --set-enabled "$repo" >/dev/null 2>&1; then
      echo "    enabled $repo"
    else
      echo "    found but could not enable $repo"
    fi
  fi
done

echo
echo "--- enabling EPEL ---"
if dnf install -y -q epel-release </dev/null >/dev/null 2>&1; then
  echo "    epel-release installed"
else
  echo "    !! epel-release not available"
fi
dnf -q makecache </dev/null >/dev/null 2>&1

echo
echo "--- repos after ---"
dnf -q repolist 2>/dev/null | tail -n +2 | awk '{print "    " $1}' | head -20

echo
echo "--- the two packages that were missing ---"
for p in ninja-build doxygen; do
  printf '    %-13s ' "$p"
  if dnf -q list --available "$p" >/dev/null 2>&1; then
    dnf -q list --available "$p" 2>/dev/null | tail -1 | awk '{printf "available: %s (%s)\n", $2, $3}'
  else
    echo "STILL MISSING"
  fi
done
