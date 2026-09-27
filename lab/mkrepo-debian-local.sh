#!/usr/bin/env bash
# 本机跑（不在 CI 里）：用 【root 私钥】签 Debian 线的 keyring 源。
# 这是整套设计里唯一必须由 root 签的东西 —— 所以它不进 CI，手工签。
#
# 生成 repo/debian/keyring/dists/stable/{Release,InRelease} + Packages
set -euo pipefail
cd "$(dirname "$0")/.."          # → repo/

source "$HOME/qmdmm-signing-lab/env.sh"
OUT="repo/debian/keyring"
D="$OUT/dists/stable"
ARCHDIR="$D/main/binary-all"

echo "=== 用 root 私钥签 keyring 源 ==="
echo "  root fpr = $ROOT"

mkdir -p "$ARCHDIR"
: > "$ARCHDIR/Packages"
gzip -kf "$ARCHDIR/Packages"

# apt 需要 Release 里的逐文件校验和；本机没有 apt-ftparchive，手算。
sums() {
  local f="$1" rel="$2"
  printf ' %s %16s %s\n' "$(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$rel"
}
sha() {
  local f="$1" rel="$2"
  printf ' %s %16s %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$rel"
}

{
  echo "Origin: QMdmm Signing Lab"
  echo "Label: QMdmm Signing Lab"
  echo "Suite: stable"
  echo "Codename: stable"
  echo "Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
  echo "Architectures: all"
  echo "Components: main"
  echo "Description: QMdmm signing lab — keyring source (root-signed)"
  echo "MD5Sum:"
  sums "$ARCHDIR/Packages"   "main/binary-all/Packages"
  sums "$ARCHDIR/Packages.gz" "main/binary-all/Packages.gz"
  echo "SHA256:"
  sha "$ARCHDIR/Packages"    "main/binary-all/Packages"
  sha "$ARCHDIR/Packages.gz" "main/binary-all/Packages.gz"
} > "$D/Release"

gpg --batch --yes --local-user "${ROOT}!" --clearsign -o "$D/InRelease" "$D/Release"

echo "  --- 签名者是谁 ---"
gpg --verify "$D/InRelease" 2>&1 | sed 's/^/    /'
echo "  --- 产出 ---"
find "$OUT" -type f | sort | sed 's/^/    /'
