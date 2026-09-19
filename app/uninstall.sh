#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo '请使用 root 用户运行卸载程序。'
  exit 1
fi

APP_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$APP_DIR" = '/usr/local/sbin' ]; then
  APP_DIR=${IPTV_SPIDER_DIR:-/opt/sh-iptv-spider}
fi

case "$APP_DIR" in
  /|/root|/opt|/usr|/usr/local|/etc|/var|/home|'')
    echo "拒绝使用不安全的安装目录执行卸载：$APP_DIR"
    exit 1
    ;;
esac

ask() {
  local prompt=$1 default=${2-} value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

echo 'IPTV Spider 卸载程序'
echo "安装目录：$APP_DIR"
confirm=$(ask '输入 UNINSTALL 确认停止并卸载服务' 'CANCEL')
if [ "$confirm" != 'UNINSTALL' ]; then
  echo '卸载已取消。'
  exit 0
fi

keep_config=$(ask '是否保留 config.yaml 和日志？YES/NO' 'YES')
remove_database=$(ask '是否删除 IPTV 数据库和数据库用户？YES/NO' 'NO')
remove_packages=$(ask '是否卸载由安装器使用的 MariaDB 软件包？YES/NO' 'NO')
stamp=$(date +%Y%m%d%H%M%S)
backup_dir="/root/iptv-spider-uninstall-backup-$stamp"

systemctl disable --now iptv-spider.service 2>/dev/null || true
rm -f /etc/systemd/system/iptv-spider.service
systemctl daemon-reload

if [[ "$keep_config" =~ ^([Yy][Ee][Ss])$ ]]; then
  install -d -m 0700 "$backup_dir"
  [ -f "$APP_DIR/config.yaml" ] && cp -a "$APP_DIR/config.yaml" "$backup_dir/"
  [ -d "$APP_DIR/log" ] && cp -a "$APP_DIR/log" "$backup_dir/"
  [ -f /etc/network/interfaces ] && cp -a /etc/network/interfaces "$backup_dir/interfaces"
  echo "配置备份：$backup_dir"
fi

if [[ "$remove_database" =~ ^([Yy][Ee][Ss])$ ]] && [ -f "$APP_DIR/config.yaml" ]; then
  db=$(sed -n "s/^[[:space:]]*db-name:[[:space:]]*'\([^']*\)'/\1/p" "$APP_DIR/config.yaml" | tail -n1)
  user=$(sed -n "s/^[[:space:]]*username:[[:space:]]*'\([^']*\)'/\1/p" "$APP_DIR/config.yaml" | tail -n1)
  if [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$user" =~ ^[A-Za-z0-9_.-]+$ ]] && command -v mariadb >/dev/null 2>&1; then
    mariadb -e "DROP DATABASE IF EXISTS \`$db\`;"
    for host in localhost 127.0.0.1 %; do
      mariadb -e "DROP USER IF EXISTS '$user'@'$host';"
    done
    mariadb -e 'FLUSH PRIVILEGES;'
  else
    echo '数据库名称或用户名无法安全识别，已跳过数据库删除。'
  fi
fi

if [ -f /etc/network/interfaces ] && grep -q '^# BEGIN IPTV-SPIDER ETH1$' /etc/network/interfaces; then
  tmp=$(mktemp /tmp/interfaces.XXXXXX)
  awk '
    $0 == "# BEGIN IPTV-SPIDER ETH1" {skip=1; next}
    $0 == "# END IPTV-SPIDER ETH1" {skip=0; next}
    !skip {print}
  ' /etc/network/interfaces > "$tmp"
  install -m 0644 "$tmp" /etc/network/interfaces
  rm -f "$tmp"
  echo '已移除安装器创建的 eth1 持久化配置；未重启网络。'
fi

rm -rf "$APP_DIR"
rm -f /usr/local/sbin/iptv-spider-uninstall
rm -f /usr/local/sbin/iptv-spider-status
rm -f /usr/local/sbin/iptv-spider

if [[ "$remove_packages" =~ ^([Yy][Ee][Ss])$ ]]; then
  apt-get purge -y mariadb-server mariadb-client
  apt-get autoremove -y
fi

echo 'IPTV Spider 已卸载。'
