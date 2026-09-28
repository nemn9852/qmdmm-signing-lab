#!/usr/bin/env bash
#
# Stage C: prove that tampering with a published repository is DETECTED.
#
# The file layout that gets tampered with is a property of the FORMAT
# (dists/… on deb, repodata/… on rpm, lab.db on pacman), while the command that
# re-reads it is a property of the CONSUMER (apt / dnf / pacman). So a grid cell
# is a (format, consumer) pair - and a distinct representative consumer per
# format is enough here, because the question being asked is whether the
# signature covers the content, which is format-level.
#
#   env: PAGES, LINE, VERSION, ROOT_FPR, EXPECT_SHA, FMT=deb|rpm|pac
#
# Three steps, and the order is the point:
#   1. take the metadata down into a local copy and point the consumer at file://
#   2. CONTROL: the untouched copy must refresh cleanly
#   3. tamper with one metadata file -> the same refresh must now be refused
#
# Step 2 is not decoration. Without it a failure in step 3 could be caused by
# anything at all - a mistyped file:// URL, a key that was never imported, a
# path typo - and would still look like detection. FINDINGS.md 3.7 is the story
# of exactly that mistake, so the control group here is deliberately the same
# object the tampering later modifies, not a fresh setup.
set -euo pipefail

PAGES="${PAGES:?}"; LINE="${LINE:?}"; VERSION="${VERSION:?}"
ROOT_FPR="${ROOT_FPR:?}"; EXPECT_SHA="${EXPECT_SHA:?}"; FMT="${FMT:?}"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
R="$W/site"          # the local copy of the published repository
mkdir -p "$W/keys" "$W/none" "$R"
source "$(dirname "$0")/lib-site.sh"

BASE="$PAGES/$LINE/$VERSION"

echo "=== C/taint $FMT ($LINE $VERSION) ==="
echo "  $(os_name)"

echo
echo "--- tooling ---"
case "$FMT" in
  deb) export DEBIAN_FRONTEND=noninteractive
       apt-get update -qq </dev/null
       apt-get install -y -qq --no-install-recommends gnupg curl gzip </dev/null ;;
  rpm) dnf install -y -q gnupg2 curl </dev/null >/dev/null 2>&1 || true ;;
  pac) pacman -Sy --noconfirm --needed gnupg curl >/dev/null 2>&1 || true ;;
esac

echo
echo "--- wait for the site to serve this run's publish ---"
wait_for_publish "$PAGES" "$EXPECT_SHA"

echo
echo "--- keys, from Pages only ---"
fetch "$PAGES/keys/qmdmm-root.gpg"          "$W/keys/root.gpg"
fetch "$PAGES/keys/$LINE/qmdmm-packages.gpg" "$W/keys/packages.gpg"
# apt verifies signatures as the `_apt` user, which cannot read into mktemp's
# 0700 directory - stage B hit exactly this. Here the copy is made reachable
# rather than moved, because the file:// source names it by path.
chmod 755 "$W"; chmod 644 "$W"/keys/*
sub=$(first_sub_fpr "$W/keys/packages.gpg")
echo "  this line's subkey: $sub"
[ -n "$sub" ] || { echo "  !! no subkey in the packages key file"; exit 1; }

echo
echo "--- take the metadata down (packages are not needed to verify metadata) ---"
case "$FMT" in
  deb)
    d="$R/dists/$VERSION"
    mkdir -p "$d/main/binary-all"
    fetch "$BASE/dists/$VERSION/InRelease"              "$d/InRelease"
    fetch "$BASE/dists/$VERSION/Release"                "$d/Release"
    fetch "$BASE/dists/$VERSION/main/binary-all/Packages"    "$d/main/binary-all/Packages"
    fetch "$BASE/dists/$VERSION/main/binary-all/Packages.gz" "$d/main/binary-all/Packages.gz"
    ;;
  rpm)
    mkdir -p "$R/repodata"
    fetch "$BASE/repodata/repomd.xml"     "$R/repodata/repomd.xml"
    fetch "$BASE/repodata/repomd.xml.asc" "$R/repodata/repomd.xml.asc"
    # The rest of repodata is named with a hash, so it is read out of repomd.xml
    # instead of being guessed.
    mapfile -t more < <(grep -o 'href="repodata/[^"]*"' "$R/repodata/repomd.xml" \
                        | sed 's/^href="//; s/"$//' | sort -u)
    [ "${#more[@]}" -ge 1 ] || { echo "  !! repomd.xml names no other metadata file"; exit 1; }
    for f in "${more[@]}"; do fetch "$BASE/$f" "$R/$f"; done
    ;;
  pac)
    fetch "$BASE/lab.db"     "$R/lab.db"
    fetch "$BASE/lab.db.sig" "$R/lab.db.sig"
    ;;
esac

echo
echo "--- the signature on the metadata names this line's subkey ---"
case "$FMT" in
  deb) gpg --show-keys "$W/keys/packages.gpg" >/dev/null 2>&1
       gpgv --keyring "$W/keys/packages.gpg" "$R/dists/$VERSION/InRelease" 2>&1 | sed 's/^/    /' ;;
  rpm) gpg --batch --import "$W/keys/packages.gpg" 2>/dev/null
       gpg --verify "$R/repodata/repomd.xml.asc" "$R/repodata/repomd.xml" 2>&1 | sed 's/^/    /' ;;
  pac) gpg --batch --import "$W/keys/packages.gpg" 2>/dev/null
       gpg --verify "$R/lab.db.sig" "$R/lab.db" 2>&1 | sed 's/^/    /' ;;
esac

echo
echo "--- CONTROL: the untouched copy must refresh cleanly ---"
case "$FMT" in
  deb)
    echo "deb [signed-by=$W/keys/packages.gpg] file://$R $VERSION main" \
      > /etc/apt/sources.list.d/qmdmm.list
    rm -rf /var/lib/apt/lists/*
    if ! apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/qmdmm.list \
           -o Dir::Etc::sourceparts="$W/none" > "$W/control.log" 2>&1; then
      echo "  !! the control refresh failed, so nothing below would mean anything:"
      sed 's/^/    /' "$W/control.log"; exit 1
    fi
    ;;
  rpm)
    cat > /etc/yum.repos.d/qmdmm.repo <<EOF
[qmdmm-lab]
name=QMdmm signing lab ($LINE $VERSION)
baseurl=file://$R
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$W/keys/packages.gpg
EOF
    rm -rf /var/cache/dnf /var/cache/libdnf5; dnf clean all >/dev/null 2>&1 || true
    dnf -y -q makecache > "$W/control.log" 2>&1 || true
    if grep -qiE 'signature verification error|GPG check FAILED' "$W/control.log"; then
      echo "  !! the control refresh failed, so nothing below would mean anything:"
      sed 's/^/    /' "$W/control.log"; exit 1
    fi
    ctl=$(dnf_packages qmdmm-lab "$W" || true)
    [ -n "$ctl" ] || { echo "  !! the control copy lists no package at all"; exit 1; }
    echo "  control lists: $(printf '%s' "$ctl" | tr '\n' ' ')"
    ;;
  pac)
    pacman-key --add "$W/keys/packages.gpg" 2>&1 | sed 's/^/    /'
    pacman-key --lsign-key "$sub" 2>&1 | sed 's/^/    /'
    cat >> /etc/pacman.conf <<EOF

[lab]
SigLevel = Required DatabaseRequired
Server = file://$R
EOF
    rm -rf /var/lib/pacman/sync/*
    if ! pacman -Sy --noconfirm > "$W/control.log" 2>&1; then
      echo "  !! the control refresh failed, so nothing below would mean anything:"
      sed 's/^/    /' "$W/control.log"; exit 1
    fi
    ;;
esac
echo "  OK: the untouched copy is accepted"

echo
echo "--- tamper with one metadata file ---"
case "$FMT" in
  deb)
    f="$R/dists/$VERSION/main/binary-all/Packages"
    printf '\n' >> "$f"              # one extra byte in the package index...
    gzip -kf "$f"                    # ...and a valid, freshly built Packages.gz
    echo "  appended one byte to main/binary-all/Packages and rebuilt Packages.gz"
    ;;
  rpm)
    f="$R/repodata/repomd.xml"
    printf ' ' >> "$f"
    echo "  appended one byte to repodata/repomd.xml (still well-formed XML)"
    ;;
  pac)
    f="$R/lab.db"
    printf 'x' >> "$f"
    echo "  appended one byte to lab.db"
    ;;
esac
echo "  ($(wc -c < "$f" | tr -d ' ') bytes now)"

echo
echo "--- the same refresh must now be refused ---"
case "$FMT" in
  deb)
    rm -rf /var/lib/apt/lists/*
    if apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/qmdmm.list \
           -o Dir::Etc::sourceparts="$W/none" > "$W/taint.log" 2>&1; then
      echo "  !! apt accepted the tampered metadata"; sed 's/^/    /' "$W/taint.log"; exit 1
    fi
    grep -iE 'hash sum mismatch|does not match|failed' "$W/taint.log" | head -4 | sed 's/^/    /' || true
    ;;
  rpm)
    rm -rf /var/cache/dnf /var/cache/libdnf5; dnf clean all >/dev/null 2>&1 || true
    dnf -y -q makecache > "$W/taint.log" 2>&1 || true
    # dnf makecache exits 0 on a failed check (FINDINGS.md 3.2), so the assertion
    # is that the repository can no longer be listed - not that the command failed.
    neg=$(dnf_packages qmdmm-lab "$W" || true)
    if [ -n "$neg" ]; then
      echo "  !! dnf still lists $(printf '%s' "$neg" | tr '\n' ' ') from the tampered repository"
      exit 1
    fi
    grep -iE 'signature verification error|GPG check FAILED' "$W/taint.log" | head -4 | sed 's/^/    /' || true
    ;;
  pac)
    rm -rf /var/lib/pacman/sync/*
    if pacman -Sy --noconfirm > "$W/taint.log" 2>&1; then
      echo "  !! pacman accepted the tampered database"; sed 's/^/    /' "$W/taint.log"; exit 1
    fi
    grep -iE 'invalid or corrupted|signature|error' "$W/taint.log" | head -4 | sed 's/^/    /' || true
    ;;
esac

echo
echo "  OK: the tampered copy is refused"
echo
echo "=== C/taint $FMT ($LINE $VERSION): PASS ==="
