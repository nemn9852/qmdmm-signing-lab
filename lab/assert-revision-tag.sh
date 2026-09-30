#!/usr/bin/env bash
#
# Assert that a revision names a TAG in the upstream repository.
#
# This is the guard a release run needs and a smoke run does not. Signing says
# "this artifact is worth trusting", and that statement is only traceable if the
# artifact came from something immutable. A tag is immutable; a branch is not,
# and "signed main" is a statement about nothing in particular.
#
# Why a script rather than an `if:` on the job: in a workflow_dispatch run
# `github.ref_type` describes the ref the WORKFLOW was dispatched from - the
# branch the file lives on - and says nothing about the input's value. Reading
# it answers a different question, and always answers "branch".
#
# Fails closed, and it distinguishes the two ways of not finding a tag:
#
#   - the remote could not be listed  -> says so, and does not report a verdict
#     about the revision at all. A guard that read an unreachable remote as "no
#     such tag" would be right by accident; one that read it as "fine" would be
#     wrong on purpose.
#   - the listing came back empty     -> then it says which kind of not-a-tag it
#     is, because "I named a branch" and "I made a typo" want different fixes.
#
# A full commit SHA is deliberately NOT accepted. It would be immutable too, but
# accepting it would mean the release's own record could not say which release it
# was - and the caller resolves QMDMM_REF by name, so a SHA would not resolve
# there either. Name the tag.
#
#   env: REVISION   the tag name (required); a leading refs/tags/ is accepted
#        QMDMM_REPO the upstream to ask (default: the QMdmm repository)
set -euo pipefail

REPO="${QMDMM_REPO:-https://github.com/QMdmm/QMdmm.git}"
: "${REVISION:?REVISION is required - the tag to release, e.g. 0.0.1}"

# Which spelling was typed is not the question, so a full ref is accepted.
REV="${REVISION#refs/tags/}"

if [ -z "$REV" ]; then
  echo "refusing: REVISION is empty once refs/tags/ is stripped" >&2
  exit 1
fi

# Both patterns on purpose: an annotated tag lists twice - the tag object and
# the commit it peels to - and `--refs` would drop the second line.
set +e
out=$(git ls-remote --tags "$REPO" "refs/tags/$REV" "refs/tags/$REV^{}" 2>&1)
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "could not list tags in $REPO (git ls-remote exited $rc)." >&2
  echo "This is NOT a verdict on '$REV' - the remote was never read:" >&2
  printf '  %s\n' "$out" >&2
  exit 1
fi

if [ -z "$out" ]; then
  # One more call, on the failure path only, to name the mistake.
  if git ls-remote --heads "$REPO" "refs/heads/$REV" 2>/dev/null | grep -q .; then
    echo "refusing: '$REV' is a BRANCH in $REPO, not a tag." >&2
    echo "A branch moves. Point this at the tag you mean to release." >&2
  else
    echo "refusing: '$REV' is not a tag in $REPO, and not a branch either." >&2
    echo "Tags that do exist:" >&2
    git ls-remote --tags --refs "$REPO" 2>/dev/null \
      | awk '{sub("refs/tags/", "", $2); printf "  %s\n", $2}' >&2
  fi
  exit 1
fi

# The peeled line is last, so this is the commit for an annotated tag and the
# only line for a lightweight one - either way, what would actually be packaged.
sha=$(printf '%s\n' "$out" | awk '{print $1}' | tail -1)

echo "  '$REV' is a tag in $REPO"
echo "  it resolves to $sha"
