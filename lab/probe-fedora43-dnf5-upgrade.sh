#!/usr/bin/env bash
#
# The fedora:43 repomd rejection tracks dnf5 5.2.18 (fedora:44 has the same
# rpm 6.0.2 and it works, with dnf5 5.4.3.0). dnf5 is not frozen inside a
# released Fedora - it gets updates. So the container image may be reporting a
# stale package, and "drop Fedora 43" would be a decision made about an image
# rather than about 43.
#
# This upgrades dnf5 inside fedora:43 and re-runs the same three shapes. It
# decides whether the limitation belongs to the release or to the shipped
# package version.
#
# Diagnostic: no `set -e`.
set -uo pipefail

echo "=== fedora:43 with dnf5 upgraded ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  before: rpm $(rpm --version 2>/dev/null | awk '{print $3}')  dnf5 $(dnf5 --version 2>/dev/null | head -1 | awk '{print $3}')"

# Show the evidence for whatever the upgrade does. Silencing this was a mistake:
# 'still 5.2.18' cannot be told apart from 'the command never ran'.
echo
echo "--- what the repos actually offer (refresh metadata first) ---"
dnf --refresh -q list --upgrades dnf5 librepo 2>&1 | sed 's/^/    /' | head -10
echo "    --- all dnf5 versions visible in this image's repos ---"
dnf --refresh -q --showduplicates list dnf5 2>&1 | sed 's/^/    /' | tail -6

echo
echo "--- upgrade attempt (full output) ---"
dnf upgrade -y dnf5 librepo </dev/null 2>&1 | tail -15 | sed 's/^/    /'

echo
echo "  after:  rpm $(rpm --version 2>/dev/null | awk '{print $3}')  dnf5 $(dnf5 --version 2>/dev/null | head -1 | awk '{print $3}')"

echo
echo "########## re-running the three shapes with whatever dnf5 is now installed ##########"
LINE="fedora:43+updates" ALGO=ed25519 bash /w/lab/probe-rpm-verify.sh
