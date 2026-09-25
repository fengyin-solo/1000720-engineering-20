#!/usr/bin/env bash
# 停掉 dev-up.sh 拉起的前后端服务（只按 pid 文件处理，不会误伤手工启动的服务）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/logs/dev-up"

descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    echo "$child"
    descendants "$child"
  done
}

stop_one() {
  local name="$1" pidfile="$LOG_DIR/$1.pid" pid kids i
  if [ ! -f "$pidfile" ]; then
    echo "· $name：没有 pid 记录，跳过"
    return 1
  fi
  pid=$(cat "$pidfile" 2>/dev/null || true)
  rm -f "$pidfile"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "· $name：进程已不在（清理了过期的 pid 记录）"
    return 1
  fi
  kids=$(descendants "$pid" || true)
  kill "$pid" $kids 2>/dev/null || true
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" $kids 2>/dev/null || true
  fi
  echo "✓ $name 已停止（pid $pid）"
  return 0
}

stopped=0
stop_one backend && stopped=1 || true
stop_one frontend && stopped=1 || true

if [ "$stopped" = 1 ]; then
  echo '环境已停止，重新拉起：scripts/dev-up.sh'
else
  echo '没有运行中的服务（dev-up.sh 拉起的才算）。'
fi
