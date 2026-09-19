#!/usr/bin/env bash
set -uo pipefail

# Keep database text output in UTF-8 even when the SSH client starts a C locale.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP_DIR=${IPTV_SPIDER_DIR:-/opt/sh-iptv-spider}
REPLAY_TEST=1
overall_ok=1
if [ "${1:-}" = '--skip-replay' ]; then
  REPLAY_TEST=0
elif [ -n "${1:-}" ]; then
  echo "用法：$(basename "$0") [--skip-replay]"
  exit 2
fi

CONFIG="$APP_DIR/config.yaml"
if [ ! -r "$CONFIG" ]; then
  echo "未找到 IPTV Spider 配置：$CONFIG"
  exit 1
fi

section_value() {
  local section=$1 key=$2
  awk -v section="$section" -v key="$key" '
    $0 == section ":" {inside=1; next}
    inside && $0 ~ /^[^[:space:]]/ {exit}
    inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
      value=$0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
      sub(/^[\047]/, "", value)
      sub(/[\047][[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$CONFIG"
}

http_check() {
  local label=$1 url=$2 output=$3 result
  result=$(curl -sS --connect-timeout 5 --max-time 30 -o "$output" -w '%{http_code} %{size_download} %{content_type}' "$url" 2>/dev/null || true)
  if [[ "$result" == 200\ * ]]; then
    printf '  %-12s 正常（HTTP %s）\n' "$label" "$result"
  else
    printf '  %-12s 异常（%s）\n' "$label" "${result:-无法连接}"
    overall_ok=0
  fi
}

version=$(cat "$APP_DIR/VERSION" 2>/dev/null || printf '未知')
service_state=$(systemctl is-active iptv-spider.service 2>/dev/null || true)
enabled_state=$(systemctl is-enabled iptv-spider.service 2>/dev/null || true)
restarts=$(systemctl show iptv-spider.service -p NRestarts --value 2>/dev/null || printf '未知')
active_since=$(systemctl show iptv-spider.service -p ActiveEnterTimestamp --value 2>/dev/null || true)
eth1_addr=$(ip -4 -br addr show eth1 2>/dev/null | awk '{print $3}')
lan_ip=$(section_value epg xml_url | sed -n 's#^http://\([^:/]*\).*#\1#p')
port=$(section_value system addr | sed -n 's#.*:\([0-9][0-9]*\)$#\1#p')
days=$(sed -n "/^catchup:/,/^[^ ]/s/^[[:space:]]*days:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$CONFIG" | head -n 1)
port=${port:-8888}
days=${days:-7}
base="http://127.0.0.1:$port"
listen_addr=$(ss -lnt 2>/dev/null | awk -v suffix=":$port" 'length($4)>=length(suffix) && index($4,suffix)==length($4)-length(suffix)+1 {print $4; exit}')

echo 'IPTV Spider 运行状态'
echo '------------------------------------------------------------'
echo "  软件版本：$version"
echo "  服务状态：${service_state:-未知}"
echo "  开机启动：${enabled_state:-未知}"
echo "  重启次数：${restarts:-未知}"
echo "  启动时间：${active_since:-未知}"
echo "  监听地址：${listen_addr:-未监听}"
echo "  LAN 地址：${lan_ip:-未知}"
echo "  IPTV eth1：${eth1_addr:-未配置}"

tmp_dir=$(mktemp -d /tmp/iptv-spider-status.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

echo
echo 'HTTP 接口'
http_check 'M3U' "$base/tv.m3u" "$tmp_dir/tv.m3u"
http_check 'EPG' "$base/api/epg?daysAgo=$days" "$tmp_dir/epg.xml"
http_check 'Logo' "$base/iptvlogos/CGTN.png" "$tmp_dir/logo.png"

echo
echo '播放器 / EPG 链接'
if [ -n "$lan_ip" ]; then
  echo "  TiviMate：http://$lan_ip:$port/tv.m3u"
  echo "  IPTV#：http://$lan_ip:$port/iptvsharp.m3u"
  echo "  EPG：http://$lan_ip:$port/api/epg?daysAgo=$days"
else
  echo '  未能从 config.yaml 解析 LAN 地址，无法给出链接。'
fi

xml_channels=$(grep -c '<channel ' "$tmp_dir/epg.xml" 2>/dev/null || true)
xml_programmes=$(grep -c '<programme ' "$tmp_dir/epg.xml" 2>/dev/null || true)
echo
echo 'EPG 数据'
echo "  XMLTV 频道：${xml_channels:-0}"
echo "  XMLTV 节目：${xml_programmes:-0}"

db=$(section_value mysql db-name)
user=$(section_value mysql username)
password=$(section_value mysql password)
host=$(section_value mysql path)
if command -v mariadb >/dev/null 2>&1 && [ -n "$db" ] && [ -n "$user" ] && [ -n "$host" ]; then
  db_stats=$(MYSQL_PWD="$password" mariadb --default-character-set=utf8mb4 -h "$host" -u "$user" "$db" --batch --skip-column-names -e \
    "SELECT (SELECT COUNT(*) FROM channel_infos),(SELECT COUNT(DISTINCT comm_name) FROM epg_details),(SELECT COUNT(*) FROM epg_details),(SELECT COUNT(*) FROM auth_infos),DATE_FORMAT(FROM_UNIXTIME(MIN(start_time)/1000),'%Y-%m-%d %H:%i'),DATE_FORMAT(FROM_UNIXTIME(MAX(end_time)/1000),'%Y-%m-%d %H:%i') FROM epg_details;" 2>/dev/null || true)
  IFS=$'\t' read -r db_channels db_epg_channels db_programmes auth_count first_time last_time <<< "$db_stats"
  echo "  数据库频道：${db_channels:-无法读取}"
  echo "  EPG 频道：${db_epg_channels:-无法读取}"
  echo "  数据库节目：${db_programmes:-无法读取}"
  echo "  认证记录：${auth_count:-无法读取}"
  echo "  覆盖时间：${first_time:-未知} 至 ${last_time:-未知}"
else
  echo '  数据库统计：无法读取数据库配置或缺少 mariadb 客户端'
  overall_ok=0
fi

echo
echo '近期错误日志（最近 2 小时，最多 10 条）'
errors=$(journalctl -u iptv-spider.service --since '2 hours ago' --no-pager 2>/dev/null | \
  grep -Ei 'panic|fatal|segmentation|access denied|failed|error|401|404|502' | tail -n 10 || true)
if [ -n "$errors" ]; then
  printf '%s\n' "$errors"
else
  echo '  未发现严重错误。'
fi

echo
echo '回放测试'
if [ "$REPLAY_TEST" -eq 0 ]; then
  echo '  已跳过。'
elif [ "$service_state" != 'active' ]; then
  echo '  服务未运行，无法测试。'
  overall_ok=0
elif [ -z "${db_stats:-}" ]; then
  echo '  无法读取数据库，无法选择回放样本。'
  overall_ok=0
else
  sample=$(MYSQL_PWD="$password" mariadb --default-character-set=utf8mb4 -h "$host" -u "$user" "$db" --batch --skip-column-names -e \
    "SELECT ci.mix_no,ed.start_time DIV 1000,GREATEST(60,LEAST(300,(ed.end_time-ed.start_time) DIV 1000)),ed.comm_name,ed.name FROM epg_details ed JOIN channel_infos ci ON ci.comm_name=ed.comm_name AND ci.deleted_at IS NULL JOIN channels c ON c.user_channel_id=ci.mix_no AND c.deleted_at IS NULL AND c.time_shift='1' AND c.time_shift_url<>'' WHERE ed.deleted_at IS NULL AND ed.end_time < UNIX_TIMESTAMP(NOW() - INTERVAL 10 MINUTE)*1000 ORDER BY ed.end_time DESC LIMIT 1;" 2>/dev/null || true)
  IFS=$'\t' read -r mix_no start duration channel_name programme_name <<< "$sample"
  if [ -z "${mix_no:-}" ]; then
    echo '  没有找到可用的回放样本。'
    overall_ok=0
  else
    replay_url="$base/api/catchup/stream/$mix_no/$start/$duration.ts"
    timeout 5 curl -sS -D "$tmp_dir/replay.head" -o "$tmp_dir/replay.ts" "$replay_url" 2>/dev/null || true
    replay_status=$(awk 'NR==1 {print $2}' "$tmp_dir/replay.head" 2>/dev/null)
    replay_type=$(awk -F': ' 'tolower($1)=="content-type" {gsub(/\r/,"",$2); print $2}' "$tmp_dir/replay.head" 2>/dev/null)
    replay_bytes=$(wc -c < "$tmp_dir/replay.ts" 2>/dev/null || printf '0')
    echo "  测试节目：${channel_name:-未知} / ${programme_name:-未知}"
    echo "  HTTP 状态：${replay_status:-无响应}"
    echo "  内容类型：${replay_type:-未知}"
    echo "  5 秒数据量：${replay_bytes:-0} bytes"
    if [ "$replay_status" != '200' ] || [ "${replay_bytes:-0}" -le 0 ]; then
      overall_ok=0
    fi
  fi
fi

echo '------------------------------------------------------------'
if [ "$service_state" = 'active' ] && [ "$overall_ok" -eq 1 ]; then
  exit 0
fi
exit 1
