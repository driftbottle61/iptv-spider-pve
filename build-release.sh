#!/usr/bin/env bash
# 打包本仓库的"安装件"发行包（维护者用，在仓库根运行）。
#
#   ./build-release.sh v0.3.2    打包 iptv-spider-pve-v0.3.2.tar.gz(+.sha256)
#   ./build-release.sh            ref 省略时取当前 HEAD 所在 tag
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/dist"
REF=${1:-}

case "$REF" in
  -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) echo "未知参数：$REF" >&2; exit 1 ;;
esac

cd "$ROOT"
if [ -z "$REF" ]; then
  REF=$(git describe --tags --exact-match HEAD 2>/dev/null) || {
    echo '当前 HEAD 不在 tag 上，请显式传入 ref，例如：./build-release.sh v0.3.2' >&2; exit 1; }
fi

MEMBERS=(.gitignore install.sh install-dhcp.sh pve-iptv-dhcp-create.sh install-dhcp.conf.example README.md docs)
for f in "${MEMBERS[@]}"; do
  [ -e "$f" ] || { echo "缺少打包成员：$f" >&2; exit 1; }
done

# 打包内容取自工作区，须与目标 ref 一致（否则发出去的资产和 tag 不符）
if ! git diff --quiet "$REF" -- "${MEMBERS[@]}"; then
  echo "工作区与 $REF 不一致，请先提交或切到该 ref：" >&2
  git diff --stat "$REF" -- "${MEMBERS[@]}" >&2
  exit 1
fi

ARCHIVE="iptv-spider-pve-${REF}.tar.gz"
install -d -m 0755 "$OUT"
echo "打包 $ARCHIVE ..."
# 固定 mtime/属主/排序/权限 + gzip -n：同样内容产出同样字节，便于校验与复现
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 --mode='u=rwX,go=rX' \
  -cf - "${MEMBERS[@]}" | gzip -9n > "$OUT/$ARCHIVE"
(cd "$OUT" && sha256sum "$ARCHIVE" > "$ARCHIVE.sha256")

echo
echo "产物："
ls -l "$OUT/$ARCHIVE" "$OUT/$ARCHIVE.sha256"
tar -tvzf "$OUT/$ARCHIVE"
cat "$OUT/$ARCHIVE.sha256"
