#!/usr/bin/env bash
# 消费者视角（fedora 容器）：公钥只从 Pages 取，验「日常源的元数据签名」。
# 关键断言：dnf 的 repo_gpgcheck 用 per-repo keyring ⇒ 只有该线子钥能签它。
set -euo pipefail

PAGES="${LAB_PAGES:?}"
W=/w/verify-fedora

echo "=== 环境 ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  dnf: $(dnf --version | head -1)"

echo
echo "=== 依赖 ==="
dnf install -y -q gnupg2 ca-certificates curl

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
fetch "$PAGES/keys/qmdmm-root.gpg"          "$W/root.gpg"
fetch "$PAGES/keys/fedora/qmdmm-packages.gpg" "$W/packages.gpg"
for f in "$W/root.gpg" "$W/packages.gpg"; do
  printf '  %-14s ' "$(basename "$f")"
  gpg --with-colons --import-options show-only --import "$f" 2>/dev/null \
    | awk -F: '/^pub:/{p+=1} /^sub:/{s+=1} END{printf "pub=%d sub=%d\n", p+0, s+0}'
done

mk_repo() {
  local name="$1" keyfile="$2" d
  d="/tmp/repos-$name"; rm -rf "$d"; mkdir -p "$d"
  cat > "$d/lab.repo" <<EOF
[lab]
name=QMdmm signing lab ($name)
baseurl=$PAGES/repo/fedora/daily
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file://$keyfile
EOF
  echo "$d"
}

# 包级 gpgcheck 走【全局 rpmdb】—— 所以先把公钥 import 进去
rpm --import "$W/packages.gpg"

run_scenario() {
  local name="$1" keyfile="$2" expect="$3" d out rc
  d=$(mk_repo "$(basename "$keyfile" .gpg)" "$keyfile")
  printf '\n--- %s（公钥 = %s，期望 %s）\n' "$name" "$(basename "$keyfile")" "$expect"
  rm -rf /var/cache/dnf
  set +e
  out=$(dnf -y --setopt=reposdir="$d" --disablerepo='*' --enablerepo=lab \
             --setopt=cachedir=/tmp/dnfcache makecache 2>&1)
  rc=$?
  set -e
  echo "$out" | grep -iE 'signature|GPG|error|fail|metadata|repo' | head -8 | sed 's/^/    /' || true
  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ]; then echo "    => 通过 ✓"
    else echo "    => ✗ 期望通过却失败（rc=$rc）"; return 1; fi
  else
    if [ $rc -ne 0 ]; then echo "    => 被拒 ✓（rc=$rc）"
    else echo "    => ✗ 期望被拒却通过了 —— 隔离失效！"; return 1; fi
  fi
  echo "    (dnf 给这个 repo 建的 keyring 在哪:)"
  find /tmp/dnfcache -maxdepth 2 -name 'pubring*' 2>/dev/null | sed 's/^/      /' || true
}

echo
echo "=============================================================="
echo "  rpm 线：元数据级签名（repo_gpgcheck）"
echo "=============================================================="
run_scenario "A. 日常源 + packages 公钥（含该线子钥）" "$W/packages.gpg" PASS
run_scenario "B. 日常源 + root 公钥（只主钥，不含子钥）" "$W/root.gpg"     FAIL

echo
echo "=============================================================="
echo "  通过：元数据只有该线子钥签得动（root 公钥验不了）"
echo "=============================================================="
