.PHONY: install backend frontend up down

up:
	./scripts/dev-up.sh

down:
	./scripts/dev-down.sh

install:
	cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
	cd frontend && npm install

backend:
	cd backend && ./run.sh

frontend:
	cd frontend && npm run dev
