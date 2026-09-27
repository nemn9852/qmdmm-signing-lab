#!/usr/bin/env bash
# 在 debian:sid 容器里：用「该线子钥」签一个假 apt 仓库（= 日常源）。
# 子钥私钥走 stdin（单行 base64）——不进 argv / env / 日志。
set -euo pipefail

SUB_FPR="${SUB_FPR:?SUB_FPR 未设}"
OUT="${OUT:-/w/out/debian}"
DAILY="$OUT/daily"

echo "=== 环境 ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg:  $(gpg --version | head -1)"
echo "  arch: $(dpkg --print-architecture)"

echo
echo "=== 依赖 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends gnupg gpgv apt-utils gzip ca-certificates

echo
echo "=== 从 stdin 导入子钥 ==="
IFS= read -r KEY_B64 || true   # 输入可能没有结尾换行 ⇒ read 返回非零，别让 set -e 杀掉
printf '%s' "$KEY_B64" | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64

echo "  --- secret 视图（sec# = 主钥私钥不在，符合预期）---"
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'
echo "  --- 私钥文件（应只有 1 个 = 子钥的 keygrip）---"
ls -l "$HOME/.gnupg/private-keys-v1.d/" | sed 's/^/  /'

echo
echo "=== 断言：CI 里拿不到主钥私钥 ==="
if gpg --list-secret-keys --with-colons | awk -F: '$1=="sec" && $2!="e"' | grep -q .; then
  echo "  !! 竟然有可用主钥私钥 —— 与设计不符"; exit 1
fi
echo "  OK"

echo
echo "=== 造日常源（子钥签 InRelease）==="
mkdir -p "$DAILY/dists/stable/main/binary-all"
: > "$DAILY/dists/stable/main/binary-all/Packages"
gzip -kf "$DAILY/dists/stable/main/binary-all/Packages"
( cd "$DAILY/dists/stable" && apt-ftparchive release . > Release )
gpg --batch --yes --local-user "${SUB_FPR}!" --clearsign \
    -o "$DAILY/dists/stable/InRelease" "$DAILY/dists/stable/Release"

echo "  --- 签名者是谁（应印出主钥 uid + 子钥 fpr）---"
gpg --verify "$DAILY/dists/stable/InRelease" 2>&1 | sed 's/^/  /'

echo
echo "=== 产出 ==="
find "$OUT" -type f | sort | sed 's/^/  /'
