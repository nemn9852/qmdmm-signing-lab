#!/usr/bin/env bash
# 在 fedora 容器里：用「该线子钥」签一个 rpm 包 + 仓库元数据（= 日常源）。
set -euo pipefail

SUB_FPR="${SUB_FPR:?}"
OUT="${OUT:-/w/out/fedora}"
DAILY="$OUT/daily"

echo "=== 环境 ==="
. /etc/os-release && echo "  $PRETTY_NAME"
echo "  gpg: $(gpg --version | head -1)"
echo "  rpm: $(rpm --version)"
echo "  dnf: $(dnf --version | head -1)"

echo
echo "=== 依赖 ==="
dnf install -y -q gnupg2 rpm-build createrepo_c zstd

echo
echo "=== 从 stdin 导入子钥 ==="
IFS= read -r KEY_B64 || true   # 输入可能没有结尾换行 ⇒ read 返回非零，别让 set -e 杀掉
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
echo "=== 造一个假 rpm ==="
TOP=/tmp/rpmbuild
mkdir -p "$TOP/BUILD" "$TOP/RPMS" "$TOP/SOURCES" "$TOP/SPECS" "$TOP/SRPMS"
cat > "$TOP/SPECS/lab.spec" <<'SPEC'
Name:           qmdmm-lab
Version:        1.0
Release:        1
Summary:        QMdmm signing lab test package
License:        MIT
BuildArch:      noarch

%description
Disposable test package for the QMdmm signing lab.

%prep
%build
%install
mkdir -p %{buildroot}/usr/share/qmdmm-lab
printf 'lab\n' > %{buildroot}/usr/share/qmdmm-lab/README

%files
/usr/share/qmdmm-lab/README

%changelog
* Sun Sep 27 2026 Lab <lab@example.invalid> - 1.0-1
- initial
SPEC
if ! rpmbuild -bb --define "_topdir $TOP" "$TOP/SPECS/lab.spec" > /tmp/rpmbuild.log 2>&1; then
  echo "  !! rpmbuild 失败"; tail -25 /tmp/rpmbuild.log | sed 's/^/    /'; exit 1
fi
RPM=$(find "$TOP/RPMS" -name '*.rpm' | head -1)
echo "  $RPM"

echo
echo "=== 用子钥签这个 rpm（包级签名）==="
BACKEND=$(rpm --eval '%_openpgp_sign' 2>/dev/null || true)
echo "  rpm 默认 OpenPGP 后端 = ${BACKEND:-<未定义>}"
if ! rpmsign --addsign \
      --define "_gpg_name ${SUB_FPR}" \
      --define "_openpgp_sign gpg" \
      "$RPM" 2>&1 | sed 's/^/  /'; then
  echo "  !! rpmsign 用 gpg 后端失败"; exit 1
fi
rpm -qp --qf '  已签：%{NAME}-%{VERSION}-%{RELEASE}  sig=%{SIGPGP:pgpsig}\n' "$RPM" 2>/dev/null || true

echo
echo "=== 建仓库索引 + 签元数据（repo_gpgcheck 验的就是这个）==="
mkdir -p "$DAILY"
cp "$RPM" "$DAILY/"
if ! createrepo_c --database --disable-deltarpm "$DAILY" > /tmp/createrepo.log 2>&1; then
  echo "  !! createrepo_c 失败"; tail -20 /tmp/createrepo.log | sed 's/^/    /'; exit 1
fi
gpg --batch --yes --local-user "${SUB_FPR}!" --detach-sign --armor \
    -o "$DAILY/repodata/repomd.xml.asc" "$DAILY/repodata/repomd.xml"

echo "  --- 元数据签名者是谁 ---"
gpg --verify "$DAILY/repodata/repomd.xml.asc" "$DAILY/repodata/repomd.xml" 2>&1 | sed 's/^/    /'

echo
echo "=== 产出 ==="
find "$OUT" -type f | sort | sed 's/^/  /'
