#!/usr/bin/env bash
# 一键起环境：环境预检 → 装依赖 → 校验示例数据 → 起前后端 → 可用性检查 → 给结论。
#
# 用法：
#   scripts/dev-up.sh     跑完整流程，最后给出「可以开工 / 不能开工」的结论
#   scripts/dev-down.sh   停掉本脚本拉起的前后端服务
#
# 特点：
#   - 可重复执行：已装好的依赖、已在运行的服务会自动复用，修好问题后直接重跑即可
#   - 失败可定位：每一步输出写到 logs/dev-up/steps/ 下，失败时指出步骤、原因并附日志末尾
#   - 不影响手工启动：已运行的服务（包括手工起的）会被识别并复用，不会重复起
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT/backend"
FRONTEND_DIR="$ROOT/frontend"
LOG_DIR="$ROOT/logs/dev-up"
STEP_DIR="$LOG_DIR/steps"
BACKEND_PORT=8000
FRONTEND_PORT=5173
BACKEND_HEALTH="http://127.0.0.1:${BACKEND_PORT}/api/health"
FRONTEND_URL="http://127.0.0.1:${FRONTEND_PORT}/"

mkdir -p "$STEP_DIR"

if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_BOLD=''; C_RESET=''
fi

TOTAL_STEPS=7
STEP_NO=0
STEP_NAME=''
STEP_LOG=''
RESULTS=()

step() {
  STEP_NO=$((STEP_NO + 1))
  STEP_NAME="$1"
  STEP_LOG="$STEP_DIR/$(printf '%02d' "$STEP_NO")-$2.log"
  : >"$STEP_LOG"
  printf '\n%s[%d/%d] %s%s\n' "$C_BOLD" "$STEP_NO" "$TOTAL_STEPS" "$STEP_NAME" "$C_RESET"
}

ok() {
  printf '  %s✓ %s%s\n' "$C_GREEN" "$1" "$C_RESET"
  RESULTS+=("ok|$STEP_NAME|$1")
}

print_summary() {
  printf '\n%s---- 步骤汇总 ----%s\n' "$C_BOLD" "$C_RESET"
  local i entry mark rest
  for i in "${!RESULTS[@]}"; do
    entry="${RESULTS[$i]}"
    rest="${entry#*|}"
    case "$entry" in
      ok\|*)   mark="${C_GREEN}✓${C_RESET}" ;;
      fail\|*) mark="${C_RED}✗${C_RESET}" ;;
      *)       mark='-' ;;
    esac
    printf '  %b %s：%s\n' "$mark" "${rest%%|*}" "${rest#*|}"
  done
}

# fail "原因" [日志路径]
fail() {
  local reason="$1" log="${2:-$STEP_LOG}"
  printf '  %s✗ %s%s\n' "$C_RED" "$reason" "$C_RESET"
  RESULTS+=("fail|$STEP_NAME|$reason")
  print_summary
  printf '\n%s结论：暂时不能开工%s\n' "$C_RED$C_BOLD" "$C_RESET"
  printf '卡在：第 %d 步「%s」\n' "$STEP_NO" "$STEP_NAME"
  printf '原因：%s\n' "$reason"
  if [ -s "$log" ]; then
    printf -- '---- 该步骤日志末尾（%s）----\n' "$log"
    tail -n 15 "$log" | sed 's/^/  /'
  fi
  printf '修好以后直接重跑同一条命令即可：%s\n' "$0"
  exit 1
}

# 打印监听某端口的进程 pid（无则空输出）
port_listener() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true
  elif command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -F ":$port " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true
  fi
}

# 端口是否有进程在监听（bash 内置 /dev/tcp，不依赖 lsof/ss，拿不到 pid 时的兜底）
port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# 列出 pid 的全部子孙进程
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    echo "$child"
    descendants "$child"
  done
}

kill_tree() {
  local pid="$1" kids
  kids=$(descendants "$pid" || true)
  kill "$pid" $kids 2>/dev/null || true
}

backend_alive() {
  curl -fsS --max-time 2 "$BACKEND_HEALTH" 2>/dev/null | grep -q '"ok":true'
}

frontend_alive() {
  curl -fsS --max-time 2 "$FRONTEND_URL" 2>/dev/null | grep -q 'id="app"'
}

# ---------------------------------------------------------------- 1/7 环境预检
step '环境预检（python3 / node / npm / curl 与版本）' preflight
for cmd in python3 node npm curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "找不到命令：$cmd（请先安装再重跑）"
done
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
  || fail "python3 需要 ≥ 3.10，当前：$(python3 --version 2>&1)"
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' \
  || fail "node 需要 ≥ 18（vite 5 的要求），当前：$(node --version)"
printf '  python3 %s\n  node    %s\n  npm     %s\n' \
  "$(python3 --version 2>&1)" "$(node --version)" "$(npm --version)" | tee -a "$STEP_LOG"
ok '基础工具与版本齐全'

# ---------------------------------------------------------------- 2/7 后端依赖
step '后端依赖（backend/.venv + pip install）' backend-deps
VENV="$BACKEND_DIR/.venv"
if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -m pip --version >>"$STEP_LOG" 2>&1; then
  echo "  现有 .venv 可用（$("$VENV/bin/python" --version 2>&1)），直接复用" | tee -a "$STEP_LOG"
else
  if [ -e "$VENV" ]; then
    echo '  现有 .venv 已损坏或在其它机器上生成，删除后重建' | tee -a "$STEP_LOG"
    rm -rf "$VENV"
  fi
  if ! python3 -m venv "$VENV" >>"$STEP_LOG" 2>&1; then
    echo '  标准 venv 创建失败（常见原因：系统缺 ensurepip/python3-venv），改用 --without-pip + get-pip 兜底' | tee -a "$STEP_LOG"
    rm -rf "$VENV"
    python3 -m venv --without-pip "$VENV" >>"$STEP_LOG" 2>&1 \
      || fail 'python3 -m venv 创建虚拟环境失败（--without-pip 也不行）'
    GET_PIP="$STEP_DIR/get-pip.py"
    curl -fsSL --max-time 60 -o "$GET_PIP" https://bootstrap.pypa.io/get-pip.py >>"$STEP_LOG" 2>&1 \
      || fail '下载 get-pip.py 失败（需要能访问外网；或先装 python3-venv 再重跑）'
    "$VENV/bin/python" "$GET_PIP" >>"$STEP_LOG" 2>&1 \
      || fail 'get-pip.py 引导 pip 失败'
  fi
fi
"$VENV/bin/pip" install -r "$BACKEND_DIR/requirements.txt" >>"$STEP_LOG" 2>&1 \
  || fail 'pip install 失败（多为网络或依赖版本问题，详见日志）'
"$VENV/bin/python" -c 'import fastapi, uvicorn, pydantic' >>"$STEP_LOG" 2>&1 \
  || fail '依赖装上了但导入失败（fastapi/uvicorn/pydantic）'
ok "后端依赖就绪（$("$VENV/bin/python" --version 2>&1)）"

# ---------------------------------------------------------------- 3/7 前端依赖
step '前端依赖（frontend npm install）' frontend-deps
npm_install() {
  # node_modules 已存在时走增量 install（快，且能补上 package.json 新增的依赖）；
  # 全新安装时有 lockfile 用 npm ci 保证可复现，没有就用 npm install
  if [ -d "$FRONTEND_DIR/node_modules" ]; then
    (cd "$FRONTEND_DIR" && npm install) >>"$STEP_LOG" 2>&1
  elif [ -f "$FRONTEND_DIR/package-lock.json" ]; then
    (cd "$FRONTEND_DIR" && npm ci) >>"$STEP_LOG" 2>&1
  else
    (cd "$FRONTEND_DIR" && npm install) >>"$STEP_LOG" 2>&1
  fi
}
# 原生模块（rollup/esbuild 的平台二进制）是否匹配当前系统：
# node_modules 在别的系统或架构上装过时，npm install 不会自动补齐，这里兜底重建
native_modules_ok() {
  (cd "$FRONTEND_DIR" && node -e "
    require('rollup');
    require.resolve('@esbuild/' + process.platform + '-' + process.arch + '/package.json');
  ") >>"$STEP_LOG" 2>&1
}
npm_install || fail 'npm install 失败（详见日志）'
[ -d "$FRONTEND_DIR/node_modules" ] || fail 'npm install 跑完了但 node_modules 不存在'
if ! native_modules_ok; then
  LOCKFILE="$FRONTEND_DIR/package-lock.json"
  echo '  node_modules 里的原生模块与当前系统不匹配（多半是在其它系统上装的），删除后重装' | tee -a "$STEP_LOG"
  rm -rf "$FRONTEND_DIR/node_modules"
  if [ -f "$LOCKFILE" ]; then
    if git -C "$ROOT" ls-files --error-unmatch "${LOCKFILE#"$ROOT"/}" >/dev/null 2>&1; then
      echo '  package-lock.json 有 git 跟踪，保留不删' | tee -a "$STEP_LOG"
    else
      echo '  本地生成的 package-lock.json 同样缺当前平台的原生依赖，一并删除重建' | tee -a "$STEP_LOG"
      rm -f "$LOCKFILE"
    fi
  fi
  npm_install || fail '重装前端依赖失败（详见日志）'
  native_modules_ok || fail '重装后原生模块仍不可用：package-lock.json 可能缺少当前平台的原生依赖，请删除后重跑'
fi
ok '前端依赖就绪'

# ---------------------------------------------------------------- 4/7 示例数据
step '示例数据（养护计划 / 养护对象）' seed
(cd "$BACKEND_DIR" && .venv/bin/python - <<'PY'
from app.seed import SEED_ROWS

plans = SEED_ROWS.get("plan") or []
missing = [name for name in ("plan", "road", "bridge", "tunnel") if not SEED_ROWS.get(name)]
assert not missing, f"缺少示例数据模块：{'、'.join(missing)}"
assert all("养护对象" in row for row in plans), "养护计划缺少「养护对象」字段"
print(f"养护计划 {len(plans)} 条，养护对象来源（道路/桥梁/隧道）齐备，共 {len(SEED_ROWS)} 个业务模块")
PY
) >>"$STEP_LOG" 2>&1 || fail '内置示例数据校验失败（backend/app/seed.py 被改坏？）'
ok "$(tail -n 1 "$STEP_LOG")"

# ---------------------------------------------------------------- 5/7 启动后端
step '启动后端（uvicorn，等待健康检查）' backend-start
BACKEND_PID_FILE="$LOG_DIR/backend.pid"
BACKEND_REUSED=0
if [ -f "$BACKEND_PID_FILE" ]; then
  OLD_PID=$(cat "$BACKEND_PID_FILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    if backend_alive; then
      BACKEND_REUSED=1
      ok "后端已在运行（上次由本脚本拉起，pid $OLD_PID），直接复用"
    else
      echo "  上次拉起的后端（pid $OLD_PID）不健康，先停掉再起" | tee -a "$STEP_LOG"
      kill_tree "$OLD_PID"
      sleep 1
      rm -f "$BACKEND_PID_FILE"
    fi
  else
    rm -f "$BACKEND_PID_FILE"
  fi
fi
if [ "$BACKEND_REUSED" = 0 ] && backend_alive; then
  BACKEND_REUSED=1
  ok "后端已在运行（非本脚本拉起），直接复用（$BACKEND_HEALTH）"
fi
if [ "$BACKEND_REUSED" = 0 ]; then
  LISTENERS=$(port_listener "$BACKEND_PORT")
  if [ -n "$LISTENERS" ]; then
    fail "端口 $BACKEND_PORT 被占用（pid: $(echo $LISTENERS | tr '\n' ' ')）但不是本系统后端；请停掉占用进程后重跑"
  elif port_in_use "$BACKEND_PORT"; then
    fail "端口 $BACKEND_PORT 被占用（拿不到占用者 pid：环境缺 lsof/ss）但不是本系统后端；请停掉占用进程后重跑"
  fi
  echo "  后台启动 uvicorn（日志：$LOG_DIR/backend.log）" | tee -a "$STEP_LOG"
  (cd "$BACKEND_DIR" && exec nohup .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "$BACKEND_PORT" >>"$LOG_DIR/backend.log" 2>&1) &
  BACKEND_PID=$!
  echo "$BACKEND_PID" >"$BACKEND_PID_FILE"
  READY=0
  for _ in $(seq 1 30); do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
      rm -f "$BACKEND_PID_FILE"
      fail '后端进程启动后退出了' "$LOG_DIR/backend.log"
    fi
    if backend_alive; then READY=1; break; fi
    sleep 1
  done
  if [ "$READY" != 1 ]; then
    rm -f "$BACKEND_PID_FILE"
    fail '后端 30 秒内未通过健康检查' "$LOG_DIR/backend.log"
  fi
  ok "后端已就绪：$BACKEND_HEALTH（pid $BACKEND_PID）"
fi

# ---------------------------------------------------------------- 6/7 启动前端
step '启动前端（vite dev server，固定 5173 端口）' frontend-start
FRONTEND_PID_FILE="$LOG_DIR/frontend.pid"
FRONTEND_REUSED=0
if [ -f "$FRONTEND_PID_FILE" ]; then
  OLD_PID=$(cat "$FRONTEND_PID_FILE" 2>/dev/null || true)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    if frontend_alive; then
      FRONTEND_REUSED=1
      ok "前端已在运行（上次由本脚本拉起，pid $OLD_PID），直接复用"
    else
      echo "  上次拉起的前端（pid $OLD_PID）不健康，先停掉再起" | tee -a "$STEP_LOG"
      kill_tree "$OLD_PID"
      sleep 1
      rm -f "$FRONTEND_PID_FILE"
    fi
  else
    rm -f "$FRONTEND_PID_FILE"
  fi
fi
if [ "$FRONTEND_REUSED" = 0 ] && frontend_alive; then
  FRONTEND_REUSED=1
  ok "前端已在运行（非本脚本拉起），直接复用（$FRONTEND_URL）"
fi
if [ "$FRONTEND_REUSED" = 0 ]; then
  LISTENERS=$(port_listener "$FRONTEND_PORT")
  if [ -n "$LISTENERS" ]; then
    fail "端口 $FRONTEND_PORT 被占用（pid: $(echo $LISTENERS | tr '\n' ' ')）但不是本系统前端；请停掉占用进程后重跑"
  elif port_in_use "$FRONTEND_PORT"; then
    fail "端口 $FRONTEND_PORT 被占用（拿不到占用者 pid：环境缺 lsof/ss）但不是本系统前端；请停掉占用进程后重跑"
  fi
  echo "  后台启动 vite（日志：$LOG_DIR/frontend.log）" | tee -a "$STEP_LOG"
  (cd "$FRONTEND_DIR" && exec nohup npm run dev -- --port "$FRONTEND_PORT" --strictPort >>"$LOG_DIR/frontend.log" 2>&1) &
  FRONTEND_PID=$!
  echo "$FRONTEND_PID" >"$FRONTEND_PID_FILE"
  READY=0
  for _ in $(seq 1 60); do
    if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
      rm -f "$FRONTEND_PID_FILE"
      fail '前端进程启动后退出了' "$LOG_DIR/frontend.log"
    fi
    if frontend_alive; then READY=1; break; fi
    sleep 1
  done
  if [ "$READY" != 1 ]; then
    rm -f "$FRONTEND_PID_FILE"
    fail '前端 60 秒内未就绪' "$LOG_DIR/frontend.log"
  fi
  ok "前端已就绪：$FRONTEND_URL（pid $FRONTEND_PID）"
fi

# ---------------------------------------------------------------- 7/7 可用性检查
step '可用性检查（后端接口 / 示例数据 / 前端页面 / 代理）' smoke
curl -fsS --max-time 5 "$BACKEND_HEALTH" >"$STEP_DIR/health.json" 2>>"$STEP_LOG" \
  || fail '后端健康检查无响应'
python3 - "$STEP_DIR/health.json" >>"$STEP_LOG" 2>&1 <<'PY' || fail '后端健康检查返回内容异常'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
assert data.get("ok") is True, f"ok 字段异常：{data}"
modules = int(data.get("modules", 0))
assert modules >= 1, "业务模块数为 0，示例数据可能没加载"
print(f"后端健康：{modules} 个业务模块已加载")
PY

curl -fsS --max-time 5 "http://127.0.0.1:${BACKEND_PORT}/api/plan?size=1" >"$STEP_DIR/plan.json" 2>>"$STEP_LOG" \
  || fail '养护计划接口无响应'
python3 - "$STEP_DIR/plan.json" >>"$STEP_LOG" 2>&1 <<'PY' || fail '养护计划示例数据异常'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
items = data.get("items") or []
assert data.get("total", 0) >= 1 and items, "养护计划列表为空，示例数据未生成"
assert "养护对象" in items[0], "养护计划缺少「养护对象」字段"
print(f"养护计划共 {data['total']} 条，首条养护对象：{items[0]['养护对象']}")
PY

curl -fsS --max-time 5 "$FRONTEND_URL" 2>>"$STEP_LOG" | grep -q 'id="app"' \
  || fail '前端页面未返回预期的挂载点（id="app"）'
echo '前端页面可访问' >>"$STEP_LOG"

curl -fsS --max-time 5 "${FRONTEND_URL}api/health" 2>>"$STEP_LOG" | grep -q '"ok":true' \
  || fail '前端 /api 代理未打通（vite → 后端）'
echo '前端 /api 代理已打通' >>"$STEP_LOG"

ok '四项检查全部通过（后端健康 / 养护计划数据 / 前端页面 / 代理）'

# ---------------------------------------------------------------- 结论
print_summary
printf '\n%s结论：可以开工%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '  前端地址：%s （dev server 不会自动开浏览器，请手工访问）\n' "$FRONTEND_URL"
printf '  后端接口：%s\n' "$BACKEND_HEALTH"
printf '  服务日志：%s/backend.log、%s/frontend.log\n' "$LOG_DIR" "$LOG_DIR"
printf '  停止环境：scripts/dev-down.sh（或 make down）\n'
