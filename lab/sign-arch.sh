#!/usr/bin/env bash
# 在 archlinux 容器里：用「该线子钥」签一个假 pacman 仓库（= 日常源）。
set -euo pipefail

SUB_FPR="${SUB_FPR:?}"
OUT="${OUT:-/w/out/arch}"
DAILY="$OUT/daily"

echo "=== 环境 ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg:    $(gpg --version | head -1)"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "=== 依赖 ==="
pacman -Sy --noconfirm --needed gnupg zstd > /tmp/pacman-install.log 2>&1 || { tail -20 /tmp/pacman-install.log; exit 1; }

echo
echo "=== 从 stdin 导入子钥 ==="
IFS= read -r KEY_B64
printf '%s' "$KEY_B64" | gpg --batch --import 2>&1 | sed 's/^/  /'
unset KEY_B64
gpg --list-secret-keys --keyid-format=long | sed 's/^/  /'

echo
echo "=== 断言：没有可用主钥私钥 ==="
if gpg --list-secret-keys --with-colons | awk -F: '$1=="sec" && $2!="e"' | grep -q .; then
  echo "  !! 竟然有可用主钥私钥"; exit 1
fi
echo "  OK"

echo
echo "=== 造一个假包（.pkg.tar.zst）==="
P=/tmp/pkgroot; rm -rf "$P"; mkdir -p "$P"
cat > "$P/.PKGINFO" <<'EOF'
pkgname = qmdmm-lab
pkgver = 1.0-1
pkgdesc = QMdmm signing lab test package
url = https://example.invalid
builddate = 1758960000
packager = QMdmm signing lab
size = 4
arch = any
EOF
mkdir -p "$DAILY"
PKG="$DAILY/qmdmm-lab-1.0-1-any.pkg.tar.zst"
( cd "$P" && tar -cf - .PKGINFO ) | zstd -q -f -o "$PKG"

echo
echo "=== repo-add 建库并用子钥签（db 签名 + 包签名）==="
cd "$DAILY"
repo-add -s -k "$SUB_FPR" lab.db.tar.gz qmdmm-lab-1.0-1-any.pkg.tar.zst 2>&1 | sed 's/^/  /'

echo "  --- 签名文件 ---"
ls -l ./*.sig 2>/dev/null | sed 's/^/    /' || echo "    （没有 .sig —— 值得注意）"

echo "  --- db 签名归谁 ---"
if [ -f lab.db.tar.gz.sig ]; then
  gpg --verify lab.db.tar.gz.sig lab.db.tar.gz 2>&1 | sed 's/^/    /'
fi

echo
echo "=== 把 repo-add 建的符号链接换成实体文件（Pages/artifact 不保留 symlink）==="
for base in lab.db lab.files; do
  if [ -L "$base" ]; then
    rm -f "$base" "$base.sig"
    cp "${base}.tar.gz" "$base"
    cp "${base}.tar.gz.sig" "$base.sig" 2>/dev/null || true
    echo "  $base -> 实体文件（并复制 ${base}.tar.gz.sig -> ${base}.sig）"
  fi
done
ls -l lab.db* lab.files* 2>/dev/null | sed 's/^/    /'

echo
echo "=== 产出 ==="
find "$OUT" -type f | sort | sed 's/^/  /'
