# 市政道路桥梁养护平台

面向市政道路桥梁的巡查、病害登记、养护施工、检测评定与设施档案的一体化养护管理后台。

这是一个前后端分离的管理平台：前端 Vue 3 + Vite + TypeScript，后端 FastAPI（Python）。
两边各自独立启动，前端 dev server 已关掉自动打开页面，启动后按终端打印的地址手工打开。

## 目录结构

```text
.
├── frontend/                 Vue 3 + Vite + TypeScript 前端
│   ├── src/views/            每个业务模块一个页面
│   ├── src/api/              统一请求封装
│   ├── src/stores/           会话与筛选状态
│   └── vite.config.ts        dev server 配置（open: false）
├── backend/                  FastAPI（Python） 后端
│   ├── app/routers/          每个业务模块一组接口
│   ├── app/services/         业务规则与状态流转
│   └── app/store.py          内存数据仓库与示例数据
├── .gitignore
└── docker-compose.yml
```

## 启动

### 一键起整套环境（推荐新同事使用）

```bash
./dev.sh up        # 或 make up
```

这一条命令会按顺序做完并打印每一步结论，失败会明确指出卡在哪一步、原因和日志位置：

1. 检查 `python3` / `node` / `npm` 是否就绪、端口是否被占；
2. 准备后端依赖：在 `backend/.venv` 建虚拟环境并装 `requirements.txt`。
   已有的 venv 不可用时（换过机器、缺 pip 等）会自动重建；系统缺 `ensurepip`
   （Debian/Ubuntu 没装 `python3-venv`）时会自动改用 `--without-pip` + `get-pip.py` 引导；
3. 准备前端依赖：`npm install`。检测到 `node_modules` 是别的平台装的、vite 跑不起来时
   （典型表现为缺 `@rollup/rollup-<平台>` 原生包），会自动删掉 `node_modules` 与
   `package-lock.json` 按当前平台重装；
4. 离线校验示例数据：养护计划与道路/桥梁/隧道等养护对象必须齐全（`scripts/check_seed.py`）；
5. 启动后端，轮询 `GET /api/health`，并确认 18 个业务模块已加载；
6. 启动前端 vite，确认页面可访问、`/api` 代理能打通后端，并冒烟验证
   `GET /api/plan` 真的能取到养护计划示例数据。

全部通过后会打印「环境已就绪，可以开工」和前后端地址。任何一步失败都会立即退出、
给出关键报错与完整日志路径，修好后直接重跑 `./dev.sh up` 即可，已完成的步骤会复用。

辅助命令：

```bash
./dev.sh status          # 只看前后端与代理当前是否可用，不改动任何东西
./dev.sh logs [be|fe]    # 跟踪后端/前端日志（.dev/logs/ 下）
./dev.sh down            # 停掉由脚本启动的前后端（手工启动的不受影响）
./dev.sh up --fresh      # 删除已有 venv/node_modules 全部重装重启
BACKEND_PORT=9000 ./dev.sh up   # 默认端口被占时换端口
```

脚本运行期产物（日志、pid 等）统一放在 `.dev/`（已在 `.gitignore` 中忽略）；
依赖仍装在原位置（`backend/.venv`、`frontend/node_modules`），
下面的手工启动方式和目录结构完全不受影响。

### 后端

```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./run.sh
```

健康检查：`curl http://127.0.0.1:8000/api/health`

### 前端

```bash
cd frontend
npm install
npm run dev
```

前端默认监听 `http://127.0.0.1:5173/`，dev server 不会自动打开浏览器，
需要自己访问。`/api` 由 vite 代理到后端 `http://127.0.0.1:8000`。

## 业务模块

| 模块 | 目录 | 业务对象 | 主要字段 |
| --- | --- | --- | --- |
| 道路设施 | `road` | 道路设施 | 设施编码、道路名称、道路等级 |
| 桥梁档案 | `bridge` | 桥梁设施 | 桥梁编码、桥梁名称、桥梁类型 |
| 隧道设施 | `tunnel` | 隧道设施 | 隧道编码、隧道名称、隧道长度 |
| 巡查任务 | `patrol` | 巡查单 | 巡查单号、巡查路线、巡查人员 |
| 病害登记 | `disease` | 病害记录 | 病害编号、所在设施、病害类型 |
| 技术评定 | `assess` | 评定记录 | 评定编号、评定对象、评定周期 |
| 养护计划 | `plan` | 养护计划 | 计划编号、养护类型、养护对象 |
| 养护施工 | `work` | 施工任务 | 施工编号、关联计划、承接单位 |
| 竣工验收 | `accept` | 验收单 | 验收单号、关联施工、验收项目 |
| 坑槽修补 | `pothole` | 修补单 | 修补单号、所在路段、修补面积 |
| 裂缝处置 | `crack` | 处置单 | 处置单号、所在路段、裂缝类型 |
| 排水设施 | `drain` | 排水设施 | 设施编号、设施类型、所在道路 |
| 照明设施 | `light` | 照明设施 | 设施编号、灯杆编号、灯具类型 |
| 养护材料 | `material` | 养护材料 | 材料编号、材料名称、规格型号 |
| 养护机械 | `equip` | 养护机械 | 机械编号、机械名称、机械型号 |
| 养护资金 | `fund` | 资金记录 | 资金编号、费用类别、项目名称 |
| 公众诉求 | `complaint` | 诉求记录 | 诉求编号、诉求来源、诉求内容 |
| 设施档案 | `archive` | 档案记录 | 档案编号、关联设施、档案类型 |

## 约定

- 每个模块的前端页面在 `frontend/src/views/<模块>/index.vue`，后端接口在
  `backend/app/routers/<模块>.py`，业务规则在 `backend/app/services/<模块>.py`。
- 列表接口统一返回 `{ items, total, page, size }`，动作接口统一返回 `{ ok, message }`。
- 状态流转只允许在 `app/services` 里改，路由层不做业务判断。
