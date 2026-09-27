#!/usr/bin/env bash
#
# Shared by the verify scripts.
#
# Why this exists: Pages serves the gh-pages branch, and publishing to a branch
# is asynchronous - the push returns immediately, the build and its CDN
# invalidation do not. A verify job that starts right after publish therefore
# reads the PREVIOUS site, which looks like a broken signature scheme rather
# than a stale deploy. (That is exactly what happened on the first run.)
#
# So publish drops a publish.json naming the commit it built, and every verify
# waits for the site to actually serve that commit before asserting anything.

wait_for_publish() {
  local pages="$1" expect="$2" got="" raw="" i
  for i in $(seq 1 60); do
    # curl exits 22 on an HTTP error; under `set -e` that would kill the
    # script, so swallow it and treat "no answer" as "not yet".
    raw=$(curl -fsSL --max-time 15 "$pages/publish.json" 2>/dev/null || true)
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
