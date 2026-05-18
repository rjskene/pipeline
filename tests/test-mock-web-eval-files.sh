#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

# Group 1 — file existence
assert "mock-web/index.html exists"     "[ -f '$REPO_ROOT/mock-web/index.html' ]"
assert "mock-web/app.js exists"         "[ -f '$REPO_ROOT/mock-web/app.js' ]"
assert "mock-web/style.css exists"      "[ -f '$REPO_ROOT/mock-web/style.css' ]"
assert "Dockerfile.mock-web-eval exists" "[ -f '$REPO_ROOT/Dockerfile.mock-web-eval' ]"
assert "compose.mock-web-eval.yml exists" "[ -f '$REPO_ROOT/compose.mock-web-eval.yml' ]"

# Group 2 — index.html declares the three interaction regions
IDX="$REPO_ROOT/mock-web/index.html"
assert "index has toggle button"        "grep -q 'id=\"toggle-btn\"' '$IDX'"
assert "index has toggle panel"         "grep -q 'id=\"toggle-panel\"' '$IDX'"
assert "index has toggle indicator"     "grep -q 'id=\"toggle-indicator\"' '$IDX'"
assert "index has echo form"            "grep -q 'id=\"echo-form\"' '$IDX'"
assert "index has echo input"           "grep -q 'id=\"echo-input\"' '$IDX'"
assert "index has echo output"          "grep -q 'id=\"echo-output\"' '$IDX'"
assert "index has list root"            "grep -q 'id=\"item-list\"' '$IDX'"
assert "index has list add button"      "grep -q 'id=\"item-add\"' '$IDX'"
assert "index loads app.js"             "grep -q 'src=\"app.js\"' '$IDX'"
assert "index loads style.css"          "grep -q 'href=\"style.css\"' '$IDX'"

# Group 3 — app.js wires the three interactions
APP="$REPO_ROOT/mock-web/app.js"
assert "app.js binds toggle-btn click"   "grep -qE 'toggle-btn.*addEventListener|getElementById..toggle-btn..\..*addEventListener' '$APP'"
assert "app.js flips toggle-panel hidden" "grep -q 'toggle-panel' '$APP' && grep -q 'hidden' '$APP'"
assert "app.js flips indicator class"     "grep -q 'toggle-indicator' '$APP' && grep -qE 'classList\.(toggle|add|remove)' '$APP'"
assert "app.js binds echo-form submit"    "grep -q 'echo-form' '$APP' && grep -q 'submit' '$APP'"
assert "app.js writes to echo-output"     "grep -q 'echo-output' '$APP'"
assert "app.js binds item-add"            "grep -q 'item-add' '$APP'"
assert "app.js mutates item-list"         "grep -q 'item-list' '$APP' && grep -qE 'appendChild|insertAdjacentHTML' '$APP'"
assert "app.js supports list item remove" "grep -qE 'removeChild|\.remove\(' '$APP'"
assert "app.js <= 100 lines"              "[ \"\$(wc -l < '$APP')\" -le 100 ]"

# Group 4 — style.css indicator states
CSS="$REPO_ROOT/mock-web/style.css"
assert "style.css defines .indicator.off"  "grep -qE '\.indicator\.off' '$CSS'"
assert "style.css defines .indicator.on"   "grep -qE '\.indicator\.on' '$CSS'"
assert "style.css off has background"      "grep -A2 '\.indicator\.off' '$CSS' | grep -qE 'background(-color)?'"
assert "style.css on has background"       "grep -A2 '\.indicator\.on' '$CSS' | grep -qE 'background(-color)?'"

# Group 4b — style.css #item-add button restyle (#254)
assert "style.css defines #item-add selector"     "grep -qE '#item-add[[:space:]]*\\{' '$CSS'"
assert "style.css #item-add has green background" "awk '/#item-add[[:space:]]*\\{/,/\\}/' '$CSS' | grep -qiE 'background(-color)?:[[:space:]]*#16a34a'"
assert "style.css #item-add has white color"      "awk '/#item-add[[:space:]]*\\{/,/\\}/' '$CSS' | grep -qiE 'color:[[:space:]]*(#fff|#ffffff|white)'"
assert "style.css #item-add has border-radius 8px" "awk '/#item-add[[:space:]]*\\{/,/\\}/' '$CSS' | grep -qE 'border-radius:[[:space:]]*8px'"
assert "style.css #item-add has padding"          "awk '/#item-add[[:space:]]*\\{/,/\\}/' '$CSS' | grep -qE 'padding:[[:space:]]*8px[[:space:]]+16px'"
assert "style.css #item-add has border:none/0"    "awk '/#item-add[[:space:]]*\\{/,/\\}/' '$CSS' | grep -qE 'border:[[:space:]]*(none|0)'"
assert "style.css defines #item-add:hover"        "grep -qE '#item-add:hover[[:space:]]*\\{' '$CSS'"
assert "style.css #item-add:hover has darker green" "awk '/#item-add:hover[[:space:]]*\\{/,/\\}/' '$CSS' | grep -qiE 'background(-color)?:[[:space:]]*#15803d'"

# Group 5 — gitignore excludes host UID/GID env file
GI="$REPO_ROOT/.gitignore"
assert ".gitignore excludes mock-web/.env.mock-web-eval" "grep -qE '^/?mock-web/\.env\.mock-web-eval\$' '$GI'"

# Group 6 — Dockerfile.mock-web-eval structure (deterministic pins)
DF="$REPO_ROOT/Dockerfile.mock-web-eval"
assert "Dockerfile uses Node LTS base"          "grep -qE '^FROM node:[0-9]+(\.[0-9]+)*(-[a-z]+)?\$|^FROM node:lts' '$DF'"
assert "Dockerfile pins @anthropic-ai/claude-code@2.1.143" "grep -qF '@anthropic-ai/claude-code@2.1.143' '$DF'"
assert "Dockerfile pins @playwright/mcp@0.0.75"           "grep -qF '@playwright/mcp@0.0.75' '$DF'"
assert "Dockerfile pins serve@14.2.6"                     "grep -qF 'serve@14.2.6' '$DF'"
assert "Dockerfile installs Chromium with deps" "grep -qE 'playwright install --with-deps chromium' '$DF'"
assert "Dockerfile installs gh CLI"             "grep -qE 'apt-get install.*gh|cli\.github\.com' '$DF'"
assert "Dockerfile declares UID build arg"      "grep -qE '^ARG HOST_UID' '$DF'"
assert "Dockerfile declares GID build arg"      "grep -qE '^ARG HOST_GID' '$DF'"
assert "Dockerfile creates non-root user"       "grep -qE 'useradd|adduser' '$DF' && grep -qE 'USER ' '$DF'"
assert "Dockerfile WORKDIR is /workspace"       "grep -qE '^WORKDIR /workspace' '$DF'"

# Group 7 — compose.mock-web-eval.yml structure
CF="$REPO_ROOT/compose.mock-web-eval.yml"
assert "compose defines service mock-web-eval"  "grep -qE '^[[:space:]]+mock-web-eval:' '$CF'"
SERVICE_COUNT=$(grep -cE '^[[:space:]]{2}[a-z][a-z0-9-]*:' "$CF" 2>/dev/null || echo 0)
assert "compose has exactly one service"        "[ \"$SERVICE_COUNT\" -eq 1 ]"
assert "compose uses Dockerfile.mock-web-eval"  "grep -q 'Dockerfile.mock-web-eval' '$CF'"
assert "compose sources .env.mock-web-eval"     "grep -q 'mock-web/.env.mock-web-eval' '$CF'"
assert "compose binds .claude credentials RO"   "grep -qE '\.claude/\.credentials\.json.*:ro' '$CF'"
assert "compose binds .claude settings RO"      "grep -qE '\.claude/settings\.json.*:ro' '$CF'"
assert "compose binds .claude plugins RO"       "grep -qE '\.claude/plugins.*:ro' '$CF'"
assert "compose binds .gitconfig RO"            "grep -qE '\.gitconfig.*:ro' '$CF'"
assert "compose binds .config/gh RO"            "grep -qE '\.config/gh.*:ro' '$CF'"
assert "compose binds project root via PIPELINE_PROJECT_ROOT" "grep -qE '\\\$\\{PIPELINE_PROJECT_ROOT\\}:\\\$\\{PIPELINE_PROJECT_ROOT\\}' '$CF'"
assert "compose working_dir uses PIPELINE_WORKTREE_PATH"      "grep -qE 'working_dir:.*\\\$\\{PIPELINE_WORKTREE_PATH' '$CF'"
assert "compose no longer pins \${PWD}:\${PWD} bind"          "! grep -qE '\\\$\\{PWD\\}:\\\$\\{PWD\\}' '$CF'"
assert "compose maps HOST_PORT to 3000"         "grep -qE '\\\$\\{HOST_PORT\\}:3000' '$CF'"
assert "compose uses HOST_UID build-arg"        "grep -qE 'HOST_UID' '$CF'"
assert "compose uses HOST_GID build-arg"        "grep -qE 'HOST_GID' '$CF'"

# Group 8 — port probe helper
PROBE="$REPO_ROOT/scripts/mock-web-eval-probe-port.sh"
assert "probe script exists"          "[ -f '$PROBE' ]"
assert "probe script is executable"   "[ -x '$PROBE' ]"
assert "probe scans 8080..8089"       "grep -qE '8080.*8089|seq 8080 8089|\\{8080\\.\\.8089\\}' '$PROBE'"
assert "probe writes HOST_PORT="      "grep -qE 'HOST_PORT=' '$PROBE'"
assert "probe writes to env file"     "grep -q 'mock-web/.env.mock-web-eval' '$PROBE'"
assert "probe writes HOST_UID/GID seed" "grep -qE 'HOST_UID=' '$PROBE' && grep -qE 'HOST_GID=' '$PROBE'"
assert "probe writes PIPELINE_PROJECT_ROOT="  "grep -qE 'PIPELINE_PROJECT_ROOT=' '$PROBE'"

# Group 9 — counter section
assert "index has counter section"      "grep -q 'id=\"counter-section\"' '$IDX'"
assert "index has counter inc button"   "grep -q 'id=\"counter-inc\"' '$IDX'"
assert "index has counter dec button"   "grep -q 'id=\"counter-dec\"' '$IDX'"
assert "index has counter value span"   "grep -q 'id=\"counter-value\"' '$IDX'"
assert "counter value has aria-live=polite" "grep -E 'id=\"counter-value\"[^>]*aria-live=\"polite\"|aria-live=\"polite\"[^>]*id=\"counter-value\"' '$IDX' >/dev/null"
assert "app.js binds counter-inc click" "grep -q 'counter-inc' '$APP' && grep -qE 'counter-inc.*addEventListener|getElementById..counter-inc..\..*addEventListener' '$APP'"
assert "app.js binds counter-dec click" "grep -q 'counter-dec' '$APP' && grep -qE 'counter-dec.*addEventListener|getElementById..counter-dec..\..*addEventListener' '$APP'"
assert "app.js writes counter-value"    "grep -q 'counter-value' '$APP'"
assert "style.css defines #counter-section flex" "grep -A3 '#counter-section' '$CSS' | grep -qE 'display:\s*flex'"
assert "style.css styles #counter-value"          "grep -qE '#counter-value' '$CSS'"

# Group 10 — footer
assert "index has page-footer"            "grep -q 'id=\"page-footer\"' '$IDX'"
assert "index has build-timestamp span"   "grep -q 'id=\"build-timestamp\"' '$IDX'"
assert "app.js sets build-timestamp"      "grep -q 'build-timestamp' '$APP' && grep -qE 'toLocaleString|toISOString' '$APP'"
assert "app.js prefixes Built:"           "grep -qE \"Built:\" '$APP'"
assert "style.css styles #page-footer"   "grep -qE '#page-footer[[:space:]]*\\{' '$CSS'"
assert "footer has top border"            "grep -A4 '#page-footer' '$CSS' | grep -qE 'border-top'"
assert "footer has muted color"           "grep -A6 '#page-footer' '$CSS' | grep -qE 'color:[[:space:]]*#[0-9a-fA-F]{3,6}|color:[[:space:]]*(gray|grey|dimgray)'"

# Group 11 — .mcp.json Playwright MCP wiring
MCP="$REPO_ROOT/.mcp.json"
assert ".mcp.json exists at repo root"           "[ -f \"$MCP\" ]"
assert ".mcp.json is valid JSON"                  "jq empty <\"$MCP\" 2>/dev/null"
assert ".mcp.json registers playwright server"    "jq -e .mcpServers.playwright <\"$MCP\" >/dev/null"
assert ".mcp.json playwright command is npx"      "jq -er .mcpServers.playwright.command <\"$MCP\" | grep -qx npx"
assert ".mcp.json playwright args include @playwright/mcp" \
  "jq -r .mcpServers.playwright.args[] <\"$MCP\" | grep -q @playwright/mcp"
assert ".mcp.json pins @playwright/mcp to 0.0.75 (matches Dockerfile)" \
  "jq -r .mcpServers.playwright.args[] <\"$MCP\" | grep -q @playwright/mcp@0.0.75"
PCFG="$REPO_ROOT/pipeline.config.example"
assert "pipeline.config.example exists"                   "[ -f \"$PCFG\" ]"
assert "pipeline.config.example PIPELINE_SYNC_FILES contains .mcp.json" \
  "grep -E '^PIPELINE_SYNC_FILES=\"[^\"]*\.mcp\.json' \"$PCFG\""

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
