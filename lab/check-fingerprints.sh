#!/usr/bin/env bash
#
# Assert that keys/fingerprints.txt names each line's CURRENT operational subkey.
#
# Why this exists as a gate rather than as care: the file is hand-maintained and
# the publish job pastes it onto the front page of the site. The first three
# rotations left it naming the outgoing - by then revoked - subkeys of fedora,
# rocky and arch, so the published list was advertising exactly the key an
# incident plan says not to use, while the published key FILE next to it carried
# the current one. Nothing caught it, because nothing looked.
#
# What is compared is the list against the committed key files, so this is a
# check on their agreement and not a second copy of the fingerprints. The lines
# come from lab/lines.tsv - the lab's one list of lines - so a new line cannot
# show up in one place and not the other without this failing.
#
# Exit status is the verdict; the lines it prints say which line disagreed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Without gpg every comparison below would come out empty and be reported as a
# missing subkey, which is a wrong diagnosis dressed as a real one.
command -v gpg >/dev/null || { echo "!! gpg is not installed, so nothing here can be compared"; exit 1; }

# 40 hex characters, grouped 4-4-4-4-4, as the file prints them.
group20() { printf '%s' "$1" | sed -E 's/(....)/\1 /g; s/ $//'; }

# The fingerprint of the first subkey that can still sign (FINDINGS 3.14's
# neighbour: gpg hides revoked subkeys by default, and this lab's rotated key
# files carry one, so "the first subkey" is the wrong question after a rotation).
live_sub() {  # live_sub <key-file>
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^pub:/{f=0} /^sub:/{s=$2;f=1} /^fpr:/{if(f && s !~ /^[redi]$/){print $10; exit}}'
}

mapfile -t lines < <(awk -F'\t' 'NR>1{print $1}' lab/lines.tsv | sort -u)
[ "${#lines[@]}" -ge 1 ] || { echo "!! lab/lines.tsv lists no lines"; exit 1; }

echo "=== keys/fingerprints.txt vs the committed key files ==="
fail=0
for line in "${lines[@]}"; do
  # Anchored on the line name, and the name is escaped out of lines.tsv rather
  # than guessed: a filter that accidentally matches another row would compare
  # the wrong fingerprint, and the row it grabbed by mistake would then be the
  # one that "agrees".
  want=$(sed -nE "s/^[[:space:]]+${line}[[:space:]]+([0-9A-F]{4}([[:space:]]+[0-9A-F]{4})+)[[:space:]]*\$/\1/p" \
           keys/fingerprints.txt | tr -d '[:space:]')
  if [ -z "$want" ]; then
    # Empty is not "nothing to check": it means the row is missing or its
    # fingerprint is not in the shape this file uses, and both are the same
    # failure one level down from a wrong value.
    echo "!! $line: no parseable fingerprint row in keys/fingerprints.txt"
    fail=1; continue
  fi
  if [ "${#want}" != 40 ]; then
    echo "!! $line: '${want}' is ${#want} characters, not 40"
    fail=1; continue
  fi
  f="keys/$line/qmdmm-packages.gpg"
  if [ ! -f "$f" ]; then
    echo "!! $line: $f does not exist"; fail=1; continue
  fi
  got=$(live_sub "$f")
  if [ -z "$got" ]; then
    echo "!! $line: $f carries no usable subkey"; fail=1; continue
  fi
  if [ "$want" != "$got" ]; then
    echo "!! $line: the list says   $(group20 "${want:0:20}") ..."
    echo "           ${f} says $got"
    fail=1
  else
    echo "  $line: $(group20 "${want:0:20}")  (matches the live subkey)"
  fi
done

if [ "$fail" != 0 ]; then
  echo "!! keys/fingerprints.txt and the published key files disagree."
  echo "   lab/rotate-line-local.sh rewrites the row it rotates; a disagreement"
  echo "   here means a rotation or an edit got past it."
  exit 1
fi
echo "OK: all ${#lines[@]} listed lines name their key file's live subkey"
