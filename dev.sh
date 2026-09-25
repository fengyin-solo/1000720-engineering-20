#!/usr/bin/env bash
# 一条命令带起整套本地开发环境：
#   环境检查 -> 依赖准备（可自愈）-> 示例数据校验 -> 启动后端 -> 健康探活
#   -> 启动前端 -> 页面/代理探活 -> 给出能否开工的结论
#
# 用法：
#   ./dev.sh            等价于 ./dev.sh up
#   ./dev.sh up         安装/修复依赖并拉起前后端，最后做可用性检查
#   ./dev.sh status     只检查当前服务状态，不装依赖、不启动
#   ./dev.sh logs [fe|be] 跟踪前端/后端日志（默认两个一起）
#   ./dev.sh down       停掉由本脚本启动的前后端
#   ./dev.sh up --fresh 忽略已有依赖与在跑服务，全部重装重启
#
# 设计约束：不改变原有的手工启动方式（backend/run.sh、frontend/npm run dev），
# 所有运行期产物（日志、pid、虚拟环境、node_modules）都放在原有位置或 .dev/ 下。
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
RUN_DIR="$ROOT_DIR/.dev"
LOG_DIR="$RUN_DIR/logs"
PID_DIR="$RUN_DIR/pids"
BE_LOG="$LOG_DIR/backend.log"
FE_LOG="$LOG_DIR/frontend.log"
BE_PIDFILE="$PID_DIR/backend.pid"
FE_PIDFILE="$PID_DIR/frontend.pid"
BE_VERSION_LOG="$LOG_DIR/backend-versions.txt"

BACKEND_PORT="${BACKEND_PORT:-8000}"
FRONTEND_PORT="${FRONTEND_PORT:-5173}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-60}"   # 单个服务等待就绪的最长秒数
FRESH=0

# ----- 终端输出 -------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }
ok()    { printf '%s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn()  { printf '%s[提示]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail()  { printf '%s[失败]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
detail(){ printf '       %s\n' "$1"; }

# 打印某步失败后的统一排障指引并退出
abort() {
  local msg="$1"; local log="${2:-}"
  fail "$msg"
  if [ -n "$log" ] && [ -f "$log" ]; then
    detail "日志最后 15 行（完整日志：$log）："
    tail -n 15 "$log" | sed 's/^/         /' >&2
  fi
  detail "修好问题后直接重跑：./dev.sh up"
  exit 1
}

mkdir -p "$LOG_DIR" "$PID_DIR"

# ----- 基础工具 -------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# HTTP GET，成功（2xx/3xx）返回 0 并把 body 打到 stdout；不依赖 curl 也能跑
http_get() {
  local url="$1"
  if have curl; then
    curl -fsS --max-time 5 "$url"
  else
    python3 - "$url" <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=5) as resp:
        sys.stdout.write(resp.read().decode("utf-8"))
except Exception as exc:
    sys.stderr.write(str(exc))
    sys.exit(1)
PY
  fi
}

# 端口是否已有进程在监听（用 bash /dev/tcp 探测，不依赖 lsof/ss）
port_open() {
  local host="$1" port="$2"
  (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; }
  return 1
}

pid_alive() {
  local pidfile="$1"
  [ -f "$pidfile" ] || return 1
  local pid
  pid="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# 递归结束整棵进程树（vite/uvicorn 可能派生子进程），先 TERM 再 KILL
kill_tree() {
  local signal="$1" pid="$2"
  kill -0 "$pid" 2>/dev/null || return 0
  if have pgrep; then
    local child
    while IFS= read -r child; do
      [ -n "$child" ] && kill_tree "$signal" "$child"
    done < <(pgrep -P "$pid" 2>/dev/null)
  fi
  kill "-$signal" "$pid" 2>/dev/null || true
}

# 从 vite 日志里解析实际监听端口（5173 被占时 vite 会自动换端口）
vite_port() {
  local p
  p="$(grep -oE 'http://127\.0\.0\.1:[0-9]+/?' "$FE_LOG" 2>/dev/null | tail -n 1 | grep -oE '[0-9]+' | tail -n 1)"
  echo "${p:-$FRONTEND_PORT}"
}

# 轮询直到条件命令成功或超时；参数：超时秒数、提示语、pidfile（可空）、条件命令...
# 等待期间如果 pidfile 里的进程已经退出，则立即返回失败，不再傻等超时。
wait_for() {
  local timeout="$1"; shift
  local desc="$1"; shift
  local pidfile="$1"; shift
  local waited=0
  while ! "$@"; do
    if [ -n "$pidfile" ] && [ -f "$pidfile" ] && ! kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
      return 2   # 进程已退出
    fi
    slept=$((waited % 5))
    if [ "$slept" -eq 0 ] && [ "$waited" -gt 0 ]; then detail "仍在等待：$desc（${waited}s）"; fi
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
  done
  return 0
}

# 从日志里挑最能说明问题的错误行（取最后一处匹配，通常对应真正的异常）
log_error_hint() {
  local log="$1"
  [ -f "$log" ] || return 0
  grep -aE 'Error|Traceback|Exception|错误|地址已在使用|Address already in use|EADDRINUSE|Permission denied|ModuleNotFound|ImportError' "$log" | tail -n 4
}

# ----- 环境检查 -------------------------------------------------------------
check_prerequisites() {
  step "1/6 检查本机环境"
  local missing=0

  if have python3; then
    ok "python3：$(python3 --version 2>&1)"
  else
    fail "缺少 python3（后端需要 3.10+），请先安装 Python 3"
    missing=1
  fi

  if have node; then
    ok "node：$(node --version)"
  else
    fail "缺少 node（前端需要 Node.js 18+），请先安装 Node.js"
    missing=1
  fi

  if have npm; then
    ok "npm：$(npm --version)"
  else
    fail "缺少 npm，请随 Node.js 一起安装"
    missing=1
  fi

  if ! have curl; then
    warn "未安装 curl，HTTP 探活将改用 python3 兜底"
  fi

  [ "$missing" -eq 0 ] || abort "基础工具不齐全，补齐后再重跑"

  if port_open 127.0.0.1 "$BACKEND_PORT" && ! backend_healthy; then
    abort "端口 $BACKEND_PORT 已被其他进程占用且不是可用的后端服务。
       请先停掉占用进程，或用 BACKEND_PORT=其他端口 ./dev.sh up 重跑"
  fi
  if port_open 127.0.0.1 "$FRONTEND_PORT"; then
    if frontend_healthy; then
      warn "端口 $FRONTEND_PORT 上已有前端页面在响应（可能是手工启动的或上一次没关干净）；本脚本将再启一份，vite 会自动换端口，互不影响"
    else
      warn "端口 $FRONTEND_PORT 已被占用，vite 启动时会自动换端口（稍后以实际端口为准）"
    fi
  fi
}

# ----- 依赖准备 -------------------------------------------------------------
backend_venv_ok() {
  [ -x "$BACKEND_DIR/.venv/bin/python" ] || return 1
  "$BACKEND_DIR/.venv/bin/python" -m pip --version >/dev/null 2>&1 || return 1
  "$BACKEND_DIR/.venv/bin/python" -c "import fastapi, uvicorn" >/dev/null 2>&1
}

# 创建一个带 pip 的虚拟环境。标准方式失败（典型：Debian 缺 python3.x-venv，
# ensurepip 不可用）时，用 --without-pip 建环境再从 get-pip.py 引导 pip。
create_backend_venv() {
  local venv_dir="$BACKEND_DIR/.venv"
  local get_pip="$RUN_DIR/get-pip.py"

  if (cd "$BACKEND_DIR" && python3 -m venv .venv) >>"$BE_LOG" 2>&1 \
     && "$venv_dir/bin/python" -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  warn "标准 venv 创建失败（通常是系统缺 ensurepip / python3-venv 包），尝试无 pip 模式 + get-pip.py 引导"
  rm -rf "$venv_dir"
  if ! (cd "$BACKEND_DIR" && python3 -m venv --without-pip .venv) >>"$BE_LOG" 2>&1; then
    detail "--without-pip 模式也失败了，通常是 python3-venv 包未安装，请安装后重跑"
    rm -rf "$venv_dir"
    return 1
  fi
  if [ ! -s "$get_pip" ]; then
    detail "下载 get-pip.py（缓存到 $get_pip）"
    if have curl; then
      curl -fsS https://bootstrap.pypa.io/get-pip.py -o "$get_pip" >>"$BE_LOG" 2>&1
    else
      python3 -c "import urllib.request; urllib.request.urlretrieve('https://bootstrap.pypa.io/get-pip.py', '$get_pip')" >>"$BE_LOG" 2>&1
    fi
  fi
  if [ ! -s "$get_pip" ]; then
    detail "get-pip.py 下载失败，请检查网络；或用系统包管理器安装 python3-venv 后重跑"
    rm -rf "$venv_dir"
    return 1
  fi
  if ! "$venv_dir/bin/python" "$get_pip" >>"$BE_LOG" 2>&1; then
    detail "get-pip.py 引导 pip 失败"
    rm -rf "$venv_dir"
    return 1
  fi
  "$venv_dir/bin/python" -m pip --version >/dev/null 2>&1 || { rm -rf "$venv_dir"; return 1; }
}

install_backend() {
  step "2/6 准备后端依赖（Python venv）"
  if [ "$FRESH" -eq 1 ] && [ -d "$BACKEND_DIR/.venv" ]; then
    warn "--fresh：删除旧虚拟环境 $BACKEND_DIR/.venv"
    rm -rf "$BACKEND_DIR/.venv"
  fi

  if ! backend_venv_ok; then
    if [ -d "$BACKEND_DIR/.venv" ]; then
      warn "发现已有的 backend/.venv 不可用（解释器缺失、缺 pip 或依赖不全，常见于换过机器/Python 版本），自动重建"
    else
      detail "创建虚拟环境：python3 -m venv backend/.venv"
    fi
    rm -rf "$BACKEND_DIR/.venv"
    if ! create_backend_venv; then
      abort "创建虚拟环境失败。Debian/Ubuntu 可执行 sudo apt install python3-venv 后重跑；
       脚本也会自动尝试 --without-pip + get-pip.py 兜底引导" "$BE_LOG"
    fi
  fi

  detail "安装/核对 requirements.txt（首次较慢，日志：$BE_LOG）"
  if ! "$BACKEND_DIR/.venv/bin/pip" install --disable-pip-version-check -r "$BACKEND_DIR/requirements.txt" >>"$BE_LOG" 2>&1; then
    abort "后端依赖安装失败，多为网络/镜像源或 requirements.txt 版本问题" "$BE_LOG"
  fi

  {
    echo "# 由 ./dev.sh 记录的本次可用依赖版本（手工启动仍以 requirements.txt 为准）"
    "$BACKEND_DIR/.venv/bin/python" --version
    "$BACKEND_DIR/.venv/bin/pip" freeze
  } > "$BE_VERSION_LOG"
  ok "后端依赖就绪：$("$BACKEND_DIR/.venv/bin/python" --version 2>&1)"
}

install_frontend() {
  step "3/6 准备前端依赖（npm）"
  if [ "$FRESH" -eq 1 ]; then
    warn "--fresh：删除 frontend/node_modules"
    rm -rf "$FRONTEND_DIR/node_modules"
  fi

  vite_runs() { (cd "$FRONTEND_DIR" && node_modules/.bin/vite --version) >/dev/null 2>&1; }

  local need_install=0
  if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
    need_install=1
  elif ! node -e "require.resolve('vite/bin/vite.js', {paths:['$FRONTEND_DIR/node_modules']})" >/dev/null 2>&1; then
    need_install=1
  fi

  if [ "$need_install" -eq 1 ]; then
    detail "安装前端依赖：npm install（首次较慢，日志：$FE_LOG）"
    if ! (cd "$FRONTEND_DIR" && npm install --no-fund --no-audit) >>"$FE_LOG" 2>&1; then
      abort "前端依赖安装失败，多为网络问题；可尝试切换 npm 镜像后重跑（已装好的部分会被复用）" "$FE_LOG"
    fi
  fi

  if ! vite_runs; then
    # npm 的已知问题：node_modules 从别的平台/机器拷贝过来时，会缺当前平台的
    # optional 原生包（如 @rollup/rollup-linux-arm64-gnu），直接 npm install
    # 会报 up to date 跳过；连 package-lock.json 一起删掉重装才能补齐。
    warn "node_modules 与当前平台不匹配或缺原生包（vite 无法运行，常见于从其他机器拷贝依赖）"
    detail "删除 node_modules 与 package-lock.json 后重新安装（会按当前平台重新生成 lock）"
    rm -rf "$FRONTEND_DIR/node_modules" "$FRONTEND_DIR/package-lock.json"
    if ! (cd "$FRONTEND_DIR" && npm install --no-fund --no-audit) >>"$FE_LOG" 2>&1; then
      abort "前端依赖重装失败，多为网络问题，可切换 npm 镜像后重跑" "$FE_LOG"
    fi
  fi

  if ! vite_runs; then
    abort "vite 始终无法运行，请查看 $FE_LOG 中的原生依赖报错" "$FE_LOG"
  fi

  local vite_ver; vite_ver="$(cd "$FRONTEND_DIR" && node_modules/.bin/vite --version 2>/dev/null)"
  ok "前端依赖就绪：vite ${vite_ver#vite/}"
}

# ----- 示例数据 -------------------------------------------------------------
check_seed() {
  step "4/6 校验示例数据（养护计划与养护对象）"
  if ! python3 "$ROOT_DIR/scripts/check_seed.py" "$BACKEND_DIR"; then
    abort "示例数据校验未通过，请按上面的提示修复 backend/app/seed.py"
  fi
}

# ----- 服务探活 -------------------------------------------------------------
backend_healthy() {
  http_get "http://127.0.0.1:$BACKEND_PORT/api/health" 2>/dev/null | grep -q '"ok": *true'
}

frontend_healthy() {
  local port="$FRONTEND_PORT"
  [ -f "$FE_PIDFILE" ] && port="$(vite_port)"
  http_get "http://127.0.0.1:$port/" 2>/dev/null | grep -q '<div id="app">'
}

proxy_healthy() {
  # 经 vite 代理访问后端，验证前后端链路而不只是各活各的
  local port
  port="$(vite_port)"
  http_get "http://127.0.0.1:$port/api/health" 2>/dev/null | grep -q '"ok": *true'
}

start_backend() {
  step "5/6 启动后端并探活（127.0.0.1:$BACKEND_PORT）"
  if pid_alive "$BE_PIDFILE" && backend_healthy; then
    ok "后端已在运行（pid $(cat "$BE_PIDFILE")），直接复用"
    return
  fi
  if backend_healthy; then
    warn "端口 $BACKEND_PORT 上已有健康的后端服务（不是本脚本启动的），直接复用，不重复启动"
    return
  fi

  : > "$BE_LOG"
  # 启动前再确认一次端口没有被别人抢走，避免新进程崩溃时误把旧服务的健康响应当成功
  if port_open 127.0.0.1 "$BACKEND_PORT"; then
    rm -f "$BE_PIDFILE"
    abort "端口 $BACKEND_PORT 被其他进程占用，后端无法绑定。请停掉占用进程或换 BACKEND_PORT 后重跑"
  fi
  # 用 exec 让子 shell 直接变成 uvicorn，pidfile 记录的就是服务进程本身；
  # 不走 setsid，避免在 macOS/不同 util-linux 版本上 PID 对不上。
  (
    cd "$BACKEND_DIR"
    exec .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port "$BACKEND_PORT"
  ) >>"$BE_LOG" 2>&1 &
  echo $! > "$BE_PIDFILE"

  wait_for "$STARTUP_TIMEOUT" "后端 /api/health 就绪" "$BE_PIDFILE" backend_healthy
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if pid_alive "$BE_PIDFILE"; then kill_tree TERM "$(cat "$BE_PIDFILE")"; sleep 1; kill_tree KILL "$(cat "$BE_PIDFILE")"; fi
    rm -f "$BE_PIDFILE"
    local hint; hint="$(log_error_hint "$BE_LOG")"
    if [ "$rc" -eq 2 ]; then
      abort "后端进程启动后退出，没通过健康检查。关键报错：${hint:-见日志}" "$BE_LOG"
    fi
    abort "后端在 ${STARTUP_TIMEOUT}s 内没有起来。关键报错：${hint:-见日志}" "$BE_LOG"
  fi
  if ! pid_alive "$BE_PIDFILE"; then
    abort "后端进程已退出" "$BE_LOG"
  fi

  local modules
  modules="$(http_get "http://127.0.0.1:$BACKEND_PORT/api/health" 2>/dev/null | grep -oE '"modules": *[0-9]+' | grep -oE '[0-9]+')"
  ok "后端就绪（pid $(cat "$BE_PIDFILE")，业务模块 ${modules:-?} 个）"
}

start_frontend() {
  step "6/6 启动前端并探活（vite dev server）"
  if pid_alive "$FE_PIDFILE" && frontend_healthy; then
    ok "前端已在运行（pid $(cat "$FE_PIDFILE")），直接复用"
    return
  fi

  : > "$FE_LOG"
  (
    cd "$FRONTEND_DIR"
    export VITE_PROXY_TARGET="http://127.0.0.1:$BACKEND_PORT"
    exec node_modules/.bin/vite
  ) >>"$FE_LOG" 2>&1 &
  echo $! > "$FE_PIDFILE"

  wait_for "$STARTUP_TIMEOUT" "vite dev server 就绪" "$FE_PIDFILE" frontend_healthy
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if pid_alive "$FE_PIDFILE"; then kill_tree TERM "$(cat "$FE_PIDFILE")"; sleep 1; kill_tree KILL "$(cat "$FE_PIDFILE")"; fi
    rm -f "$FE_PIDFILE"
    local hint; hint="$(log_error_hint "$FE_LOG")"
    if [ "$rc" -eq 2 ]; then
      abort "前端进程启动后退出，页面无响应。关键报错：${hint:-见日志}" "$FE_LOG"
    fi
    abort "前端在 ${STARTUP_TIMEOUT}s 内没有起来。关键报错：${hint:-见日志}" "$FE_LOG"
  fi

  local fe_port; fe_port="$(vite_port)"
  ok "前端就绪（pid $(cat "$FE_PIDFILE")，实际端口 $fe_port）"

  if [ "$fe_port" != "$FRONTEND_PORT" ]; then
    warn "默认端口 $FRONTEND_PORT 被占用，vite 已自动切换到 $fe_port"
  fi

  detail "验证经前端代理访问后端 /api/health ..."
  if ! proxy_healthy; then
    abort "前端起来了，但 /api 代理到后端失败（前端可用、后端链路不可用），请检查 $FE_LOG" "$FE_LOG"
  fi
  ok "前后端链路打通：http://127.0.0.1:$fe_port -> /api -> 后端 :$BACKEND_PORT"

  # 业务冒烟：养护计划列表必须真的能取到示例数据
  local plans
  plans="$(http_get "http://127.0.0.1:$BACKEND_PORT/api/plan?size=1" 2>/dev/null | grep -oE '"total": *[0-9]+' | grep -oE '[0-9]+' || true)"
  if [ -n "${plans:-}" ] && [ "$plans" -gt 0 ] 2>/dev/null; then
    ok "业务冒烟通过：养护计划接口返回示例数据 ${plans} 条"
  else
    abort "后端健康但养护计划接口 /api/plan 取不到数据，示例数据可能未加载" "$BE_LOG"
  fi

  print_summary "$fe_port"
}

print_summary() {
  local fe_port="$1"
  printf '\n%s%s========================================%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '%s%s 环境已就绪，可以开工%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '%s========================================%s\n' "$C_GREEN" "$C_RESET"
  detail "前端页面：http://127.0.0.1:$fe_port/"
  detail "后端接口：http://127.0.0.1:$BACKEND_PORT/api/health"
  detail "养护计划：http://127.0.0.1:$BACKEND_PORT/api/plan"
  detail "后端日志：$BE_LOG"
  detail "前端日志：$FE_LOG"
  detail "停止环境：./dev.sh down    查看状态：./dev.sh status"
}

# ----- 子命令 ---------------------------------------------------------------
cmd_status() {
  step "服务状态"
  local rc=0
  if pid_alive "$BE_PIDFILE" && backend_healthy; then
    ok "后端运行中（pid $(cat "$BE_PIDFILE")，http://127.0.0.1:$BACKEND_PORT/api/health 正常）"
  elif backend_healthy; then
    ok "后端端口正常响应（非本脚本启动的进程）"
  else
    fail "后端未运行或健康检查不通过（日志：$BE_LOG）"
    rc=1
  fi

  local fe_port="$FRONTEND_PORT"
  if pid_alive "$FE_PIDFILE"; then
    fe_port="$(vite_port)"
    if http_get "http://127.0.0.1:$fe_port/" 2>/dev/null | grep -q '<div id="app">'; then
      ok "前端运行中（pid $(cat "$FE_PIDFILE")，端口 $fe_port）"
    else
      fail "前端进程在但页面无响应（端口 $fe_port，日志：$FE_LOG）"; rc=1
    fi
  else
    fail "前端未运行（日志：$FE_LOG）"; rc=1
  fi

  if [ "$rc" -eq 0 ] && http_get "http://127.0.0.1:$fe_port/api/health" 2>/dev/null | grep -q '"ok": *true'; then
    ok "前端 /api 代理到后端正常"
  else
    fail "前端 /api 代理不通"; rc=1
  fi
  return "$rc"
}

stop_pidfile() {
  local name="$1" pidfile="$2"
  if pid_alive "$pidfile"; then
    local pid; pid="$(cat "$pidfile")"
    kill_tree TERM "$pid"
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do sleep 1; waited=$((waited + 1)); done
    kill_tree KILL "$pid"
    ok "已停止 $name（pid $pid）"
  else
    warn "$name 未在运行"
  fi
  rm -f "$pidfile"
}

cmd_down() {
  step "停止本地环境"
  stop_pidfile "前端" "$FE_PIDFILE"
  stop_pidfile "后端" "$BE_PIDFILE"
  ok "完成（手工启动的服务不受影响）"
}

cmd_logs() {
  local target="${1:-all}"
  case "$target" in
    be|backend)  exec tail -n 100 -f "$BE_LOG" ;;
    fe|frontend) exec tail -n 100 -f "$FE_LOG" ;;
    all)
      exec tail -n 100 -f "$BE_LOG" "$FE_LOG"
      ;;
    *) abort "未知日志目标：$target（可选 be / fe）" ;;
  esac
}

cmd_up() {
  check_prerequisites
  install_backend
  install_frontend
  check_seed
  start_backend
  start_frontend
}

# ----- 入口 -----------------------------------------------------------------
ACTION="${1:-up}"
[ $# -gt 0 ] && shift || true
case "${ACTION}" in
  up)
    while [ $# -gt 0 ]; do
      case "$1" in
        --fresh) FRESH=1 ;;
        *) abort "未知参数：$1（支持 --fresh）" ;;
      esac
      shift
    done
    cmd_up
    ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  logs)   cmd_logs "${1:-all}" ;;
  *)
    fail "未知命令：$ACTION"
    echo "支持的命令：up（默认）、status、logs [be|fe]、down；up 支持 --fresh" >&2
    exit 2
    ;;
esac
