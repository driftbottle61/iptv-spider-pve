#!/usr/bin/env bash
set -uo pipefail

APP_DIR=${IPTV_SPIDER_DIR:-/opt/sh-iptv-spider}
STATUS_CMD=/usr/local/sbin/iptv-spider-status
SERVICE=iptv-spider.service

if [ "${EUID}" -ne 0 ]; then
  echo '请使用 root 用户运行 IPTV Spider 管理菜单。'
  exit 1
fi

config_value() {
  local section=$1 key=$2
  awk -v section="$section" -v key="$key" '
    $0 == section ":" {inside=1; next}
    inside && $0 ~ /^[^[:space:]]/ {exit}
    inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
      value=$0
      sub("^[[:space:]]+" key ":[[:space:]]*", "", value)
      gsub(/^\047|\047[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$APP_DIR/config.yaml"
}

wait_for_log() {
  local pattern=$1 since=$2 offset=$3 title=$4 attempt current_size
  echo "正在等待$title完成（最多 3 分钟）..."
  for attempt in $(seq 1 90); do
    current_size=$(stat -Lc %s "$APP_DIR/latest_log" 2>/dev/null || printf '0')
    if [ "$current_size" -gt "$offset" ] && \
       tail -c "+$((offset + 1))" "$APP_DIR/latest_log" 2>/dev/null | grep -q "$pattern"; then
      echo "$title已完成。"
      return 0
    fi
    if journalctl -u "$SERVICE" --since "@$since" --no-pager 2>/dev/null | grep -q "$pattern"; then
      echo "$title已完成。"
      return 0
    fi
    systemctl is-active --quiet "$SERVICE" || return 1
    sleep 2
  done
  echo "等待超时，$title可能仍在后台运行。"
  return 1
}

manual_fetch() {
  local addr port base started response log_offset
  if ! systemctl is-active --quiet "$SERVICE"; then
    echo '服务未运行，不能抓取。请先选择 3 重启服务。'
    return 1
  fi
  addr=$(config_value system addr)
  port=${addr##*:}
  [[ "$port" =~ ^[0-9]+$ ]] || port=8888
  base="http://127.0.0.1:$port/api/run"

  echo '开始手动刷新频道和 EPG 数据。'
  log_offset=$(stat -Lc %s "$APP_DIR/latest_log" 2>/dev/null || printf '0')
  started=$(date +%s)
  response=$(curl -fsS --connect-timeout 5 --max-time 15 "$base?task=update-chi" 2>/dev/null || true)
  if [ "$response" != 'OK' ]; then
    echo '频道抓取任务启动失败。'
    return 1
  fi
  wait_for_log '频道信息列表更新完成' "$started" "$log_offset" '频道抓取' || true

  log_offset=$(stat -Lc %s "$APP_DIR/latest_log" 2>/dev/null || printf '0')
  started=$(date +%s)
  response=$(curl -fsS --connect-timeout 5 --max-time 15 "$base?task=update-epg" 2>/dev/null || true)
  if [ "$response" != 'OK' ]; then
    echo 'EPG 抓取任务启动失败。'
    return 1
  fi
  wait_for_log '更新节目信息列表完成' "$started" "$log_offset" 'EPG 抓取' || true
  echo
  "$STATUS_CMD" --skip-replay || true
}

restart_service() {
  echo '正在重启 IPTV Spider...'
  if systemctl restart "$SERVICE" && timeout 30 bash -c \
    'until systemctl is-active --quiet iptv-spider.service; do sleep 1; done'; then
    echo '服务已成功重启。'
    "$STATUS_CMD" --skip-replay || true
  else
    echo '服务重启失败，最近日志如下：'
    journalctl -u "$SERVICE" -n 30 --no-pager || true
  fi
}

describe_fetch_schedule() {
  local cron=$1 second minute hours day month weekday hour output=''
  read -r second minute hours day month weekday <<< "$cron"
  if [ "$second" = '0' ] && [[ "$minute" =~ ^[0-9]+$ ]] && \
     [[ "$hours" =~ ^[0-9]+(,[0-9]+)*$ ]] && [ "$day" = '*' ] && \
     [ "$month" = '*' ] && [ "$weekday" = '*' ]; then
    IFS=',' read -r -a hour_list <<< "$hours"
    for hour in "${hour_list[@]}"; do
      printf -v output '%s%s%02d:%02d' "$output" "${output:+、}" "$((10#$hour))" "$((10#$minute))"
    done
    echo "每天 $output（上海时间）"
  else
    echo "自定义 cron：$cron（上海时间）"
  fi
}

edit_fetch_schedule() {
  local current hours minute normalized='' hour cron backup tmp
  current=$(config_value epg fetch_cron)
  echo "当前抓取计划：$(describe_fetch_schedule "$current")"
  echo "当前 cron：${current:-未设置}"
  echo
  read -r -p '每天抓取的小时，使用逗号分隔 [8,16,23]：' hours
  hours=${hours:-8,16,23}
  hours=${hours//[[:space:]]/}
  IFS=',' read -r -a hour_list <<< "$hours"
  if [ "${#hour_list[@]}" -eq 0 ]; then
    echo '小时列表不能为空。'
    return 1
  fi
  for hour in "${hour_list[@]}"; do
    if ! [[ "$hour" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
      echo "无效小时：$hour；请输入 0 到 23。"
      return 1
    fi
    hour=$((10#$hour))
    case ",$normalized," in
      *",$hour,"*) ;;
      *) normalized="${normalized:+$normalized,}$hour" ;;
    esac
  done
  read -r -p '每次抓取的分钟 [0]：' minute
  minute=${minute:-0}
  if ! [[ "$minute" =~ ^([0-9]|[1-5][0-9])$ ]]; then
    echo '分钟必须是 0 到 59。'
    return 1
  fi
  minute=$((10#$minute))
  cron="0 $minute $normalized * * *"
  echo "新抓取计划：$(describe_fetch_schedule "$cron")"
  read -r -p '确认保存并重启服务？[y/N]：' confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo '已取消。'; return 0; }

  backup="$APP_DIR/config.yaml.schedule-backup-$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp "$APP_DIR/config.yaml.schedule.XXXXXX")
  cp -a "$APP_DIR/config.yaml" "$backup"
  awk -v cron="$cron" '
    $0 == "epg:" {inside=1}
    inside && $0 ~ /^[^[:space:]]/ && $0 != "epg:" {inside=0}
    inside && $0 ~ /^[[:space:]]+fetch_cron:/ {
      print "  fetch_cron: \047" cron "\047"
      replaced=1
      next
    }
    {print}
    END {if (!replaced) exit 2}
  ' "$APP_DIR/config.yaml" > "$tmp" || {
    rm -f "$tmp"
    echo '更新配置失败，原配置未改变。'
    return 1
  }
  chmod --reference="$APP_DIR/config.yaml" "$tmp"
  chown --reference="$APP_DIR/config.yaml" "$tmp"
  mv "$tmp" "$APP_DIR/config.yaml"

  if systemctl restart "$SERVICE" && timeout 30 bash -c \
    'until systemctl is-active --quiet iptv-spider.service; do sleep 1; done'; then
    echo "抓取计划已更新：$(describe_fetch_schedule "$cron")"
    echo "配置备份：$backup"
  else
    echo '新计划导致服务启动失败，正在恢复原配置。'
    cp -a "$backup" "$APP_DIR/config.yaml"
    systemctl restart "$SERVICE" || true
    return 1
  fi
}

while :; do
  echo
  echo 'IPTV Spider 管理菜单'
  echo '------------------------------------------------------------'
  echo '  1、状态显示'
  echo '  2、手动抓取'
  echo '  3、重启服务'
  echo '  4、抓取计划'
  echo '  5、卸载'
  echo '  0、退出'
  echo '------------------------------------------------------------'
  read -r -p '请选择 [0-5]：' choice
  case "$choice" in
    1) "$STATUS_CMD" || true ;;
    2) manual_fetch ;;
    3) restart_service ;;
    4) edit_fetch_schedule ;;
    5)
      /usr/local/sbin/iptv-spider-uninstall
      if [ ! -x /usr/local/sbin/iptv-spider-uninstall ]; then
        echo '卸载完成，管理菜单即将退出。'
        exit 0
      fi
      ;;
    0)
      echo '已退出管理菜单，IPTV Spider 服务保持运行。'
      exit 0
      ;;
    *) echo '输入无效，请输入 0 到 5。' ;;
  esac
done
