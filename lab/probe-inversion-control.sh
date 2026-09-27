#!/usr/bin/env bash
#
# Positive control for the inverted assertion in verify-rpm.sh.
#
# verify-rpm (fedora) passes when metadata is *rejected* (EXPECT_METADATA_REJECTED=1).
# A gate that is green every run is worth nothing unless it can also go red, so
# this job proves the inversion has teeth: run the same script, with the same
# flag, on a distro where metadata verification *works* (rocky:10). It must then
# fail - and fail for the documented reason, not for an unrelated one.
#
# Expected: verify-rpm.sh exits non-zero AND says the limitation is gone.
# This script exits 0 only in that case; anything else is a failed control.
#
# Diagnostic-ish, but the point is the verdict, so keep it strict.
set -uo pipefail

PAGES="${LAB_PAGES:?}"
W=/w/verify-rpm

echo "=== positive control: does the inverted assertion actually fail when it should? ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  running verify-rpm.sh with EXPECT_METADATA_REJECTED=1 against a distro"
echo "  where metadata verification works. A PASS here would mean the flag is a"
echo "  blanket 'always green', which is the failure mode worth ruling out."

set +e
out=$(EXPECT_METADATA_REJECTED=1 LINE=rocky bash /w/lab/verify-rpm.sh 2>&1)
rc=$?
set -e
echo "$out" | sed -n '/repository-metadata signature/,$p' | sed 's/^/    /'

echo
echo "=== verdict ==="
echo "  verify-rpm.sh exit = $rc"
if [ $rc -eq 0 ]; then
  echo "  !! CONTROL FAILED: the inverted assertion passed even though metadata"
  echo "     verification works here. The flag would make the job green no matter"
  echo "     what it observed."
  exit 1
fi
if printf '%s' "$out" | grep -q 'limitation appears to be FIXED'; then
  echo "  OK: it failed, and for the documented reason (the limitation is absent here)"
  echo "  => the inversion discriminates: green means 'still broken', red means 'fixed'"
  exit 0
fi
echo "  !! CONTROL FAILED: it failed, but not for the expected reason - the run"
echo "     probably died earlier (fetch / wait_for_publish / another assertion),"
echo "     so this proves nothing about the inversion."
exit 1
