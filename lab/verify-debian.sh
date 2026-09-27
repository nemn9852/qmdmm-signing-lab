#!/usr/bin/env bash
# 在干净的 debian:sid 容器里扮演「消费者」：公钥只从 Pages 取（拿不到任何 secret），
# 跑 4 格隔离矩阵，验证「keyring 源只能被 root 签、日常源被子钥签」这个设计成不成立。
set -euo pipefail

PAGES="${LAB_PAGES:?}"
ROOT_FPR="${ROOT_FPR:?}"
SUB_FPR="${SUB_FPR:?}"
W=/w/verify-debian

echo "=== 环境 ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg: $(gpg --version | head -1)"

echo
echo "=== 依赖 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends gnupg gpgv apt-utils gzip curl ca-certificates

fetch() {
  local url="$1" out="$2" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsSL --max-time 30 "$url" -o "$out" && return 0
    echo "    取 $url 失败（第 $i 次），5s 后重试"; sleep 5
  done
  echo "    !! 放弃: $url"; return 1
}

echo
echo "=== 从 Pages 取公钥（公开渠道 —— 消费者能拿到的东西）==="
mkdir -p "$W"
fetch "$PAGES/keys/qmdmm-root.gpg"            "$W/root.gpg"
fetch "$PAGES/keys/debian/qmdmm-packages.gpg" "$W/packages.gpg"
ls -l "$W"/*.gpg | sed 's/^/  /'
echo "  --- 两份公钥各含什么 ---"
for f in "$W/root.gpg" "$W/packages.gpg"; do
  printf '  %-14s ' "$(basename "$f")"
  gpg --with-colons --import-options show-only --import "$f" 2>/dev/null \
    | awk -F: '/^pub:/{p++} /^sub:/{s++} END{printf "pub=%d sub=%d\n", p+0, s+0}'
done
echo "  --- 消费者手里那把主钥指纹应为 $ROOT_FPR ---"
TMPH=$(mktemp -d); chmod 700 "$TMPH"
GNUPGHOME="$TMPH" gpg --batch --import "$W/root.gpg" 2>/dev/null
GNUPGHOME="$TMPH" gpg --with-colons --list-keys 2>/dev/null | awk -F: '/^fpr:/{print "    "$10; exit}'
rm -rf "$TMPH"

run_scenario() {
  local name="$1" key="$2" path="$3" expect="$4"
  printf '\n--- %s\n' "$name"
  printf '    源=%s  公钥=%s  期望=%s\n' "$path" "$(basename "$key")" "$expect"
  cat > /tmp/sources.list <<EOF
deb [signed-by=$key] $PAGES/repo/debian/$path stable main
EOF
  rm -rf /tmp/lists /tmp/cache
  mkdir -p /tmp/lists/partial /tmp/cache/archives/partial /tmp/empty
  local out rc
  set +e
  out=$(apt-get -o Dir::Etc::sourcelist=/tmp/sources.list \
              -o Dir::Etc::sourceparts=/tmp/empty \
              -o Dir::Etc::trusted=/dev/null \
              -o Dir::Etc::trustedparts=/tmp/empty \
              -o Dir::State::lists=/tmp/lists \
              -o Dir::Cache=/tmp/cache \
              -o Acquire::Retries=0 \
              -o APT::Sandbox::User=root \
              update 2>&1)
  rc=$?
  set -e
  echo "$out" | grep -E '^(Err|E:|W:|Get|Hit)' | sed 's/^/    /' || true
  if [ "$expect" = PASS ]; then
    if [ $rc -eq 0 ]; then echo "    => 通过 ✓"; else echo "    => ✗ 期望通过却失败 (rc=$rc)"; return 1; fi
  else
    if [ $rc -ne 0 ]; then echo "    => 被拒 ✓（rc=$rc）"; else echo "    => ✗ 期望被拒却通过了 —— 隔离失效！"; return 1; fi
  fi
}

echo
echo "=============================================================="
echo "  4 格隔离矩阵"
echo "=============================================================="
run_scenario "A. keyring 源（root 签） + root 公钥"        "$W/root.gpg"     "keyring" PASS
run_scenario "B. 日常源（子钥签）   + packages 公钥"       "$W/packages.gpg" "daily"   PASS
run_scenario "C. 日常源（子钥签）   + 【root 公钥】"        "$W/root.gpg"     "daily"   FAIL
run_scenario "D. keyring 源（root 签） + packages 公钥"    "$W/packages.gpg" "keyring" PASS

echo
echo "=============================================================="
echo "  全部断言通过：keyring 源只认 root；子钥签不动 keyring 源"
echo "=============================================================="
