.PHONY: install backend frontend up down status logs

install:
	cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
	cd frontend && npm install

backend:
	cd backend && ./run.sh

frontend:
	cd frontend && npm run dev

# 一条命令带起整套本地环境（依赖准备 + 示例数据校验 + 前后端启动 + 可用性检查）
up:
	./dev.sh up

down:
	./dev.sh down

status:
	./dev.sh status

logs:
	./dev.sh logs
