#!/usr/bin/env bash
# 消费者视角（archlinux 容器）：pacman 的受信 key 全在【全局 keyring】，
# 没有 per-repo 限定 ⇒ 这族「源内隔离」做不到，这里把这件事做实。
set -euo pipefail

PAGES="${LAB_PAGES:?}"
ROOT_FPR="${ROOT_FPR:?}"
SUB_FPR="${SUB_FPR:?}"
W=/w/verify-arch

echo "=== 环境 ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  pacman: $(pacman --version | head -1)"

echo
echo "=== 依赖 ==="
if ! grep -qE '^[[:space:]]*Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
fi
pacman -Sy --noconfirm --needed gnupg ca-certificates curl > /tmp/pi.log 2>&1 || { tail -20 /tmp/pi.log; exit 1; }

fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsSL --max-time 30 "$url" -o "$out" && return 0
    echo "    取 $url 失败（第 $i 次），5s 后重试"; sleep 5
  done
  echo "    !! 放弃: $url"; return 1
}

echo
echo "=== 从 Pages 取公钥 ==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"        "$W/root.gpg"
fetch "$PAGES/keys/arch/qmdmm-packages.gpg" "$W/packages.gpg"
for f in "$W/root.gpg" "$W/packages.gpg"; do
  printf '  %-14s ' "$(basename "$f")"
  gpg --with-colons --import-options show-only --import "$f" 2>/dev/null \
    | awk -F: '/^pub:/{p+=1} /^sub:/{s+=1} END{printf "pub=%d sub=%d\n", p+0, s+0}'
done

write_conf() {
  cat > /tmp/pacman-lab.conf <<EOF
[options]
Architecture = auto
SigLevel = Required DatabaseRequired
LocalFileSigLevel = Optional

[lab]
SigLevel = Required DatabaseRequired
Server = $PAGES/repo/arch/daily
EOF
}

reset_keyring() {
  rm -rf /etc/pacman.d/gnupg /var/lib/pacman/sync/*
  mkdir -p /etc/pacman.d/gnupg
  pacman-key --init > /tmp/pk-init.log 2>&1 || { tail -10 /tmp/pk-init.log; return 1; }
}

run_scenario() {
  local name="$1" keyfile="$2" fpr="$3" expect="$4" out rc
  printf '\n--- %s（导入 %s，期望 %s）\n' "$name" "$(basename "$keyfile")" "$expect"
  reset_keyring
  pacman-key --add "$keyfile" > /dev/null 2>&1
  pacman-key --lsign-key "$fpr" > /dev/null 2>&1
  write_conf
  set +e
  out=$(pacman -Sy --config /tmp/pacman-lab.conf --noconfirm 2>&1)
  rc=$?
  set -e
  echo "$out" | tail -6 | sed 's/^/    /'
  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ]; then echo "    => 通过 ✓"; else echo "    => ✗ 期望通过却失败（rc=$rc）"; return 1; fi
  else
    if [ $rc -ne 0 ]; then echo "    => 被拒 ✓（rc=$rc）"
    else echo "    => ✗ 期望被拒却通过了 —— 隔离失效！"; return 1; fi
  fi
}

echo
echo "=============================================================="
echo "  pacman 线：信任只按「key 在不在全局 keyring」，不按源"
echo "=============================================================="
run_scenario "A. 导入【该线子钥】公钥 + lsign" "$W/packages.gpg" "$SUB_FPR"  PASS
run_scenario "B. 只导入【root】公钥 + lsign"   "$W/root.gpg"     "$ROOT_FPR" FAIL

echo
echo "=============================================================="
echo "  结论：pacman 没有 per-repo 信任作用域 ——"
echo "  「谁能签这个源」不是由源配置决定的，而是由「谁被 lsign 进全局 keyring」决定的。"
echo "  ⇒ keyring 包必须带外分发（ArchWiki 的 unofficial keys 路线）。"
echo "=============================================================="
