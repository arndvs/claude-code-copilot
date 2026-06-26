.PHONY: help setup start stop test test-stream claude-enable claude-disable claude-status list-models list-models-enabled install-claude

PORT ?= 4000

help:
	@echo ""
	@echo "claude-code-copilot"
	@echo "─────────────────────────────────────────"
	@echo "  make setup               Set up .env with generated keys"
	@echo "  make start               Start LiteLLM proxy (OAuth on first run)"
	@echo "  make stop                Stop the proxy"
	@echo "  make test                Test proxy is working (non-streaming)"
	@echo "  make test-stream         Test proxy streaming (SSE) response"
	@echo ""
	@echo "  make claude-enable       Point Claude Code at local proxy"
	@echo "  make claude-disable      Restore Claude Code to Anthropic direct"
	@echo "  make claude-status       Show current Claude Code config"
	@echo ""
	@echo "  make list-models         List all available Copilot models"
	@echo "  make list-models-enabled List only enabled Copilot models"
	@echo ""
	@echo "  make install-claude      Install Claude Code CLI via npm"
	@echo ""

# ── Setup ──────────────────────────────────────────────────────

setup:
	@if [ ! -f .env ]; then \
		echo "Generating .env..."; \
		umask 077; \
		python3 -c "\
import uuid; \
mk = 'sk-' + str(uuid.uuid4()); \
open('.env','w').write('LITELLM_MASTER_KEY=' + mk + '\nLITELLM_PORT=$(PORT)\nLITELLM_LOCAL_MODEL_COST_MAP=true\n'); \
print('✅ .env created'); \
print('   LITELLM_MASTER_KEY stored in .env'); \
"; \
		chmod 600 .env; \

	else \
		echo "✅ .env already exists — skipping"; \
	fi
	@if ! command -v uv >/dev/null 2>&1; then \
		echo "Installing uv..."; \
		curl -LsSf https://astral.sh/uv/install.sh | sh; \
		if ! command -v uv >/dev/null 2>&1; then \
			echo "❌ uv was installed but is not available on PATH in this shell."; \
			echo "   The installer often places uv in $$HOME/.local/bin and requires a new shell."; \
			echo "   Add $$HOME/.local/bin to your PATH or start a new shell, then re-run 'make setup' or 'make start'."; \
			exit 1; \
		fi; \
	fi
	@echo "✅ Setup complete. Run 'make start' to start the proxy."

# ── Proxy lifecycle ────────────────────────────────────────────

start:
	@if [ ! -f .env ]; then echo "❌ .env not found. Run 'make setup' first."; exit 1; fi
	@set -a && . ./.env && set +a && \
	PORT=$${LITELLM_PORT:-$(PORT)} && \
	echo "Starting LiteLLM → GitHub Copilot proxy on port $$PORT..." && \
	UV_NATIVE_TLS=$${UV_NATIVE_TLS:-true} \
	uv run \
		--with "litellm[proxy]" \
		litellm --config litellm_config.yaml --port $$PORT

stop:
	@if [ ! -f .env ]; then echo "❌ .env not found. Run 'make setup' first."; exit 1; fi
	@set -a && . ./.env && set +a && \
	PORT=$${LITELLM_PORT:-$(PORT)} && \
	pkill -f "litellm --config .*litellm_config.yaml --port $$PORT" 2>/dev/null && echo "✅ Proxy stopped" || echo "ℹ️  No proxy process found"

# ── Test ───────────────────────────────────────────────────────

test:
	@if [ ! -f .env ]; then echo "❌ .env not found. Run 'make setup' first."; exit 1; fi
	@set -a && . ./.env && set +a && \
	PORT=$${LITELLM_PORT:-$(PORT)} && \
	MASTER_KEY=$$LITELLM_MASTER_KEY && \
	echo "Testing proxy at http://localhost:$$PORT..." && \
	curl -sf -X POST http://localhost:$$PORT/v1/messages \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $$MASTER_KEY" \
		-d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"Say hello in one word."}]}' \
	| python3 -m json.tool && echo "" && echo "✅ Proxy is working!" \
	|| { echo "❌ Test failed. Is the proxy running? ('make start')"; exit 1; }

test-stream:
	@if [ ! -f .env ]; then echo "❌ .env not found. Run 'make setup' first."; exit 1; fi
	@set -a && . ./.env && set +a && \
	PORT=$${LITELLM_PORT:-$(PORT)} && \
	MASTER_KEY=$$LITELLM_MASTER_KEY && \
	echo "Testing streaming (SSE) at http://localhost:$$PORT..." && \
	RESPONSE=$$(curl -sf -X POST http://localhost:$$PORT/v1/messages \
		-H "Content-Type: application/json" \
		-H "Authorization: Bearer $$MASTER_KEY" \
		-H "Accept: text/event-stream" \
		-d '{"model":"claude-sonnet-4-6","max_tokens":50,"stream":true,"messages":[{"role":"user","content":"Say hi."}]}') && \
	echo "$$RESPONSE" | head -20 && \
	if echo "$$RESPONSE" | grep -q 'data:'; then \
		echo "" && echo "✅ Streaming response contains SSE data lines!"; \
		if echo "$$RESPONSE" | grep -q '"upstream_empty":true'; then \
			echo "⚠️  upstream_empty:true detected in streaming response (document if expected)"; \
		else \
			echo "✅ No upstream_empty:true — streaming is delivering content"; \
		fi; \
	else \
		echo "❌ No SSE data: lines found. Is streaming enabled?"; exit 1; \
	fi \
	|| { echo "❌ Stream test failed. Is the proxy running? ('make start')"; exit 1; }

# ── Claude Code configuration ──────────────────────────────────

claude-enable:
	@if [ ! -f .env ]; then echo "❌ .env not found. Run 'make setup' first."; exit 1; fi
	@set -a && . ./.env && set +a && \
	PORT=$${LITELLM_PORT:-$(PORT)} && \
	MASTER_KEY=$$LITELLM_MASTER_KEY && \
	if [ -z "$$MASTER_KEY" ]; then echo "❌ LITELLM_MASTER_KEY not found in .env"; exit 1; fi; \
	SETTINGS_FILE="$$HOME/.claude/settings.json"; \
	if [ -f "$$SETTINGS_FILE" ]; then \
		BACKUP="$$SETTINGS_FILE.backup.$$(date +%Y%m%d_%H%M%S)"; \
		cp "$$SETTINGS_FILE" "$$BACKUP"; \
		chmod 600 "$$BACKUP"; \
		echo "📁 Backed up settings to $$BACKUP"; \
	fi; \
	LITELLM_MASTER_KEY="$$MASTER_KEY" LITELLM_PORT="$$PORT" python3 scripts/claude_enable.py

claude-disable:
	@SETTINGS_FILE="$$HOME/.claude/settings.json"; \
	if [ -f "$$SETTINGS_FILE" ]; then \
		BACKUP="$$SETTINGS_FILE.proxy_backup.$$(date +%Y%m%d_%H%M%S)"; \
		cp "$$SETTINGS_FILE" "$$BACKUP"; \
		chmod 600 "$$BACKUP"; \
		echo "📁 Backed up current settings to $$BACKUP"; \
	fi
	@python3 scripts/claude_disable.py

claude-status:
	@echo ""
	@echo "Claude Code configuration"
	@echo "─────────────────────────────────────────"
	@SETTINGS_FILE="$$HOME/.claude/settings.json"; \
	if [ -f "$$SETTINGS_FILE" ]; then \
		python3 scripts/claude_status_redact.py < "$$SETTINGS_FILE" 2>/dev/null || { echo '(could not parse settings)'; exit 0; }; \
		echo ""; \
		if grep -q "ANTHROPIC_BASE_URL" "$$SETTINGS_FILE" 2>/dev/null; then \
			PROXY_URL=$$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); env=d.get("env", {}); print(env.get("ANTHROPIC_BASE_URL", "") if isinstance(env, dict) else "")' "$$SETTINGS_FILE" 2>/dev/null); \
			if [ -z "$$PROXY_URL" ]; then \
				PORT=$$(grep LITELLM_PORT .env 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo '$(PORT)'); \
				PROXY_URL="http://localhost:$${PORT:-$(PORT)}"; \
			fi; \
			PROXY_URL=$${PROXY_URL%/}; \
			if ! python3 -c 'from urllib.parse import urlparse; import sys; p=urlparse(sys.argv[1]); sys.exit(0 if p.scheme in ("http","https") and p.netloc and p.hostname else 1)' "$$PROXY_URL"; then \
				echo "❌ Proxy URL in settings is invalid: $$PROXY_URL"; \
				exit 0; \
			fi; \
			if python3 -c 'from urllib.parse import urlparse; import sys; host=urlparse(sys.argv[1]).hostname; sys.exit(0 if host in ("localhost","127.0.0.1","::1") else 1)' "$$PROXY_URL"; then \
				echo "🔗 Routing: local proxy"; \
				PROXY_HINT="run 'make start'"; \
			else \
				echo "🔗 Routing: hosted proxy"; \
				PROXY_HINT="check the hosted proxy endpoint"; \
			fi; \
			if curl -sf "$$PROXY_URL/health/readiness" >/dev/null 2>&1; then \
				echo "✅ Proxy: running at $$PROXY_URL"; \
			else \
				echo "❌ Proxy: not running at $$PROXY_URL — $$PROXY_HINT"; \
			fi; \
		else \
			echo "🌐 Routing: Anthropic API directly"; \
		fi; \
	else \
		echo "No settings file — using Claude Code defaults (Anthropic direct)"; \
	fi
	@echo ""

# ── Model discovery ────────────────────────────────────────────

list-models:
	@./scripts/list-copilot-models.sh

list-models-enabled:
	@./scripts/list-copilot-models.sh --enabled-only

# ── Install ────────────────────────────────────────────────────

install-claude:
	@if command -v npm >/dev/null 2>&1; then \
		npm install -g @anthropic-ai/claude-code && \
		echo "✅ Claude Code installed. Run 'make setup' next."; \
	else \
		echo "❌ npm not found. Install Node.js first: https://nodejs.org/"; \
	fi
