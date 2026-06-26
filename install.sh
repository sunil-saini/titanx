#!/usr/bin/env bash
# titanx installer — stand up the Titan Ops Console Claude project and audit
# the companion CLIs / MCPs that ops-mcp hands off to for live data.
#
# ops-mcp is a HOSTED HTTP MCP server (https://api.ops.flock.com/ops-mcp), so there is
# nothing to run locally — "installing" it means registering that endpoint, which the
# scaffolded project's .mcp.json does. This script:
#   1. scaffolds the ops console project (from the bundled template) into TARGET_DIR,
#   2. checks the ops-mcp endpoint is reachable,
#   3. audits each companion (CLI preferred over MCP for all tools):
#      Grafana: gcx CLI (https://github.com/grafana/gcx) — uses GRAFANA_TOKEN from .env
#      Sentry:  sentry CLI (https://cli.sentry.dev)      — uses SENTRY_AUTH_TOKEN from .env
#      Kubernetes + GitHub: kubectl / gh; MCP accepted as fallback.
#
# Usage:
#   ./install.sh [TARGET_DIR] [-f|--force]
#     TARGET_DIR   where to create the project (default: ~/titanx)
#     -f, --force  overwrite template-managed files if the dir already exists
set -euo pipefail

OPS_MCP_URL="https://api.ops.flock.com/ops-mcp"
S3_BASE="https://s3browser.ops.riva.co/titan-logs-use/titanx"
SRC="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SRC/titanx"

DEFAULT_TARGET="$HOME/titanx"
TARGET=""
FORCE=0
for a in "$@"; do
  case "$a" in
    -f|--force) FORCE=1 ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown flag: $a" >&2; exit 2 ;;
    *)          TARGET="${a/#\~/$HOME}" ;;
  esac
done

# Color Definitions (using 256-color palette for premium aesthetics)
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"
COLOR_UNDERLINE="\033[4m"
COLOR_RESET="\033[0m"

COLOR_GREEN="\033[38;5;84m"     # Vibrant pastel green
COLOR_YELLOW="\033[38;5;220m"   # Warm gold/yellow
COLOR_RED="\033[38;5;203m"      # Warm pastel red
COLOR_CYAN="\033[38;5;86m"       # Turquoise/Cyan
COLOR_BLUE="\033[38;5;39m"       # Vivid deep blue
COLOR_PURPLE="\033[38;5;141m"   # Soft purple/magenta
COLOR_GRAY="\033[38;5;244m"     # Neutral gray

symbol_success="${COLOR_GREEN}✔${COLOR_RESET}"
symbol_warn="${COLOR_YELLOW}⚠${COLOR_RESET}"
symbol_error="${COLOR_RED}✘${COLOR_RESET}"
symbol_info="${COLOR_CYAN}ℹ${COLOR_RESET}"
symbol_arrow="${COLOR_PURPLE}➜${COLOR_RESET}"
symbol_bullet="${COLOR_GRAY}•${COLOR_RESET}"

have(){ command -v "$1" >/dev/null 2>&1; }

# Global cleanup trap
CLEANUP_FILES=()
cleanup() {
  [ ${#CLEANUP_FILES[@]} -gt 0 ] && rm -rf "${CLEANUP_FILES[@]}" || true
}
trap cleanup EXIT

# Start fetching the Claude MCP list in the background early (major speedup)
MCP_LIST_FILE="/tmp/claude_mcp_list_$$"
CLAUDE_MCP_PID=""
if have claude; then
  CLEANUP_FILES+=("$MCP_LIST_FILE")
  claude mcp list 2>/dev/null > "$MCP_LIST_FILE" &
  CLAUDE_MCP_PID=$!
fi

# mcp_present checks the user-level MCP list (captured at startup).
mcp_present(){
  if [ -n "$CLAUDE_MCP_PID" ]; then
    wait "$CLAUDE_MCP_PID" 2>/dev/null || true
    CLAUDE_MCP_PID=""
  fi
  if [ -f "$MCP_LIST_FILE" ]; then
    grep -qiw "$1" "$MCP_LIST_FILE"
  else
    return 1
  fi
}

# Tokens fetched from S3 at install time; empty if fetch failed.
TITANX_GRAFANA_TOKEN=""
TITANX_SENTRY_TOKEN=""

# fetch_tokens pulls service-account tokens from S3 (tokens.env: KEY=value lines)
# and sets the above vars. Silently no-ops if S3 is unreachable.
fetch_tokens(){
  local raw key val
  raw=$(s3_fetch "tokens.env" 2>/dev/null) || return 1
  while IFS='=' read -r key val; do
    case "$key" in
      TITANX_GRAFANA_TOKEN) TITANX_GRAFANA_TOKEN="$val" ;;
      TITANX_SENTRY_TOKEN)  TITANX_SENTRY_TOKEN="$val"  ;;
    esac
  done <<< "$raw"
}

# write_project_mcp_json writes the project .mcp.json with ops-mcp only.
# Grafana and Sentry are handled via gcx/sentry CLIs (tokens in .env);
# user-level MCPs are accepted as fallback if the CLIs aren't installed.
write_project_mcp_json(){
  local path="$1"
  printf '{\n  "mcpServers": {\n    "ops-mcp": {\n      "type": "http",\n      "url": "https://api.ops.flock.com/ops-mcp"\n    }\n  }\n}\n' > "$path"
}

# write_env_file path [inc_grafana=1] [inc_sentry=1]
# Written only when gcx or sentry CLI is absent; skips a section when flag=0.
# gcx reads GRAFANA_TOKEN; sentry CLI reads SENTRY_AUTH_TOKEN.
# Claude Code injects .env vars into the shell environment automatically.
write_env_file(){
  local path="$1" inc_grafana="${2:-1}" inc_sentry="${3:-1}"
  {
    printf '# Read-only service-account tokens — written by titanx installer\n'
    if [ "$inc_grafana" -eq 1 ]; then
      printf '# gcx (Grafana CLI): https://github.com/grafana/gcx\n'
      printf 'GRAFANA_URL=https://grafana.eks.ops.titan.email\n'
      if [ -n "$TITANX_GRAFANA_TOKEN" ]; then
        printf 'GRAFANA_TOKEN=%s\n' "$TITANX_GRAFANA_TOKEN"
      else
        printf '#GRAFANA_TOKEN=<unavailable — ask in #devops-tooling>\n'
      fi
    fi
    if [ "$inc_sentry" -eq 1 ]; then
      printf '# sentry CLI: https://cli.sentry.dev\n'
      printf 'SENTRY_URL=https://sentry.eks.ops.titan.email\n'
      if [ -n "$TITANX_SENTRY_TOKEN" ]; then
        printf 'SENTRY_AUTH_TOKEN=%s\n' "$TITANX_SENTRY_TOKEN"
      else
        printf '#SENTRY_AUTH_TOKEN=<unavailable — ask in #devops-tooling>\n'
      fi
    fi
  } > "$path"
}

# S3 browser wraps each file in HTML containing a pre-signed download link — extract and fetch it
s3_fetch(){ local u; u=$(curl -sf "$S3_BASE/$1" | grep -o 'href="[^"]*"' | head -1 | sed 's/href="//;s/"//;s/&amp;/\&/g'); [ -n "$u" ] || return 1; curl -sf "$u"; }

ALIAS_RC=""
set_titanx_alias() {
  local alias_line="alias titanx='cd \"$TARGET\" && claude'"
  case "${SHELL##*/}" in
    zsh)  ALIAS_RC="$HOME/.zshrc" ;;
    bash) ALIAS_RC="$HOME/.bashrc" ;;
    *)    echo -e "   ${symbol_warn} Shell not supported automatically. Please add this manually to your shell config:"
          echo -e "     ${COLOR_BOLD}${alias_line}${COLOR_RESET}"
          return ;;
  esac
  local tmp
  tmp="$(mktemp)"
  grep -v "^alias titanx=" "$ALIAS_RC" 2>/dev/null > "$tmp" || true
  printf '%s\n' "$alias_line" >> "$tmp"
  cat "$tmp" > "$ALIAS_RC"; rm "$tmp"
}

# --- HEADER ---
echo -e "\n${COLOR_CYAN} ${COLOR_BOLD}titanx${COLOR_RESET} ${COLOR_GRAY}│${COLOR_RESET} Titan Ops Console Installer"
echo -e "${COLOR_GRAY} ──────────────────────────────────────────────────${COLOR_RESET}\n"

# Prompt for directory if not specified
if [ -z "$TARGET" ]; then
  echo -e " ${symbol_arrow} ${COLOR_BOLD}Project Location:${COLOR_RESET}"
  printf "   Where should the titanx project live? [%s]\n   ${COLOR_GRAY}Press Enter to continue with default location, or type a path❯${COLOR_RESET} " "$DEFAULT_TARGET"
  read -r input </dev/tty
  TARGET="${input:-$DEFAULT_TARGET}"
  TARGET="${TARGET/#\~/$HOME}"
  echo
fi

# Print configuration summary
echo -e " ${COLOR_BOLD}Configuration:${COLOR_RESET}"
echo -e "   ${COLOR_GRAY}•${COLOR_RESET} ops-mcp   ${COLOR_CYAN}→${COLOR_RESET} $OPS_MCP_URL"
echo -e "   ${COLOR_GRAY}•${COLOR_RESET} Project   ${COLOR_CYAN}→${COLOR_RESET} $TARGET"
echo

if [ ! -d "$TEMPLATE" ]; then
  echo -e " ${symbol_info} Downloading project template from S3..."
  _tmp="$(mktemp -d)"
  CLEANUP_FILES+=("$_tmp")
  if s3_fetch "template.tar.gz" | tar xz -C "$_tmp"; then
    echo -e "   ${symbol_success} Successfully downloaded and extracted template."
  else
    echo -e "   ${symbol_error} Failed to download template from S3."
    echo -e "     ${COLOR_RED}Please check your VPN / corporate network connection.${COLOR_RESET}"
    exit 1
  fi
  TEMPLATE="$_tmp"
fi

# 1) scaffold ----------------------------------------------------------------
echo -e " ${COLOR_BOLD}Step 1: Scaffolding Project${COLOR_RESET}"
if [ -e "$TARGET" ] && [ "$FORCE" -ne 1 ]; then
  echo -e "   ${symbol_warn} Project directory already exists."
  echo -e "     ${COLOR_GRAY}Leaving it as-is. Run with ${COLOR_RESET}--force${COLOR_GRAY} to refresh from template.${COLOR_RESET}"
else
  mkdir -p "$TARGET"
  if cp -R "$TEMPLATE/." "$TARGET/"; then
    echo -e "   ${symbol_success} Scaffolded ops console into: ${COLOR_CYAN}$TARGET${COLOR_RESET}"
  else
    echo -e "   ${symbol_error} Failed to copy template files to $TARGET"
    exit 1
  fi
fi
echo

# 2) shell alias --------------------------------------------------------------
echo -e " ${COLOR_BOLD}Step 2: Shell Integration${COLOR_RESET}"
set_titanx_alias
if [ -n "$ALIAS_RC" ]; then
  echo -e "   ${symbol_success} Registered ${COLOR_CYAN}titanx${COLOR_RESET} alias in ${COLOR_CYAN}$ALIAS_RC${COLOR_RESET}"
  echo -e "     ${COLOR_GRAY}You can now run: ${COLOR_RESET}source $ALIAS_RC${COLOR_GRAY} (or open a new terminal)${COLOR_RESET}"
fi
echo

# 3) preflight ----------------------------------------------------------------
echo -e " ${COLOR_BOLD}Step 3: Preflight Checks${COLOR_RESET}"
if have claude; then
  echo -e "   ${symbol_success} Claude CLI detected"
else
  echo -e "   ${symbol_error} Claude CLI not found"
  echo -e "     ${COLOR_RED}Please install Claude Code first: ${COLOR_UNDERLINE}https://claude.ai/code${COLOR_RESET}"
fi

if have curl; then
  echo -e "   ${symbol_info} Checking ops-mcp reachability..."
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 6 "$OPS_MCP_URL" 2>/dev/null || echo 000)"
  if [ "$code" = "000" ]; then
    echo -e "   ${symbol_error} ops-mcp endpoint ${COLOR_RED}UNREACHABLE${COLOR_RESET}"
    echo -e "     ${COLOR_RED}Check your VPN or corporate network connection.${COLOR_RESET}"
  else
    echo -e "   ${symbol_success} ops-mcp endpoint is reachable ${COLOR_GRAY}(HTTP $code)${COLOR_RESET}"
  fi
else
  echo -e "   ${symbol_warn} curl not found — skipping reachability check"
fi

echo

# 4) companion audit ---------------------------------------------------------
missing_required=0
mcp_used=0          # any tool falling back to MCP instead of CLI
need_env_grafana=0
need_env_sentry=0

MCP_JSON="$TARGET/.mcp.json"
CLI_PREFERRED_DOC="https://www.anthropic.com/engineering/code-execution-with-mcp"

fetch_tokens
write_project_mcp_json "$MCP_JSON"

echo -e " ${COLOR_BOLD}Step 4: Auditing Companion Integrations${COLOR_RESET}"
echo -e "   ${COLOR_GRAY}CLI preferred for all tools — optimised for token usage. MCP accepted as fallback.${COLOR_RESET}\n"

# --- Observability (Grafana, Sentry) — gcx / sentry CLI preferred ---
echo -e "   ${COLOR_GRAY}Observability & Errors:${COLOR_RESET}"

padded_grafana=$(printf "%-14s" "Grafana")
if have gcx; then
  echo -e "   ${symbol_success} ${padded_grafana} ${COLOR_GRAY}→${COLOR_RESET} CLI (${COLOR_GREEN}gcx${COLOR_RESET})"
elif mcp_present "grafana"; then
  echo -e "   ${symbol_warn} ${padded_grafana} ${COLOR_GRAY}→${COLOR_RESET} MCP fallback (${COLOR_YELLOW}grafana${COLOR_RESET}) — install gcx: ${COLOR_UNDERLINE}https://github.com/grafana/gcx${COLOR_RESET}"
  echo -e "                  ${COLOR_GRAY}Endpoint: grafana.eks.ops.titan.email · token → ${COLOR_RESET}$TARGET/.env ${COLOR_GRAY}as ${COLOR_RESET}GRAFANA_TOKEN"
  mcp_used=1; need_env_grafana=1
else
  echo -e "   ${symbol_warn} ${padded_grafana} ${COLOR_GRAY}→${COLOR_RESET} not found — install gcx: ${COLOR_UNDERLINE}https://github.com/grafana/gcx${COLOR_RESET}"
  echo -e "                  ${COLOR_GRAY}Endpoint: grafana.eks.ops.titan.email · token → ${COLOR_RESET}$TARGET/.env ${COLOR_GRAY}as ${COLOR_RESET}GRAFANA_TOKEN"
  need_env_grafana=1
fi

padded_sentry=$(printf "%-14s" "Sentry")
if have sentry; then
  echo -e "   ${symbol_success} ${padded_sentry} ${COLOR_GRAY}→${COLOR_RESET} CLI (${COLOR_GREEN}sentry${COLOR_RESET})"
elif mcp_present "sentry"; then
  echo -e "   ${symbol_warn} ${padded_sentry} ${COLOR_GRAY}→${COLOR_RESET} MCP fallback (${COLOR_YELLOW}sentry${COLOR_RESET}) — install sentry CLI: ${COLOR_UNDERLINE}https://cli.sentry.dev${COLOR_RESET}"
  echo -e "                  ${COLOR_GRAY}Endpoint: sentry.eks.ops.titan.email · token → ${COLOR_RESET}$TARGET/.env ${COLOR_GRAY}as ${COLOR_RESET}SENTRY_AUTH_TOKEN"
  mcp_used=1; need_env_sentry=1
else
  echo -e "   ${symbol_warn} ${padded_sentry} ${COLOR_GRAY}→${COLOR_RESET} not found — install sentry CLI: ${COLOR_UNDERLINE}https://cli.sentry.dev${COLOR_RESET}"
  echo -e "                  ${COLOR_GRAY}Endpoint: sentry.eks.ops.titan.email · token → ${COLOR_RESET}$TARGET/.env ${COLOR_GRAY}as ${COLOR_RESET}SENTRY_AUTH_TOKEN"
  need_env_sentry=1
fi

# Write .env only when at least one observability CLI is absent
if [ "$need_env_grafana" -eq 1 ] || [ "$need_env_sentry" -eq 1 ]; then
  write_env_file "$TARGET/.env" "$need_env_grafana" "$need_env_sentry"
fi

# --- Code & infra (kubectl, gh) — CLI preferred ---
echo
echo -e "   ${COLOR_GRAY}Code & Infra:${COLOR_RESET}"

padded_k8s=$(printf "%-14s" "Kubernetes")
if have kubectl; then
  echo -e "   ${symbol_success} ${padded_k8s} ${COLOR_GRAY}→${COLOR_RESET} CLI (${COLOR_GREEN}kubectl${COLOR_RESET})"
elif mcp_present "kubernetes"; then
  echo -e "   ${symbol_warn} ${padded_k8s} ${COLOR_GRAY}→${COLOR_RESET} MCP fallback (${COLOR_YELLOW}kubernetes${COLOR_RESET}) — install kubectl: ${COLOR_UNDERLINE}https://kubernetes.io/docs/tasks/tools${COLOR_RESET}"
  mcp_used=1
else
  echo -e "   ${symbol_error} ${padded_k8s} ${COLOR_GRAY}→${COLOR_RESET} ${COLOR_RED}MISSING (REQUIRED)${COLOR_RESET}"
  echo -e "                  Install kubectl: ${COLOR_UNDERLINE}https://kubernetes.io/docs/tasks/tools${COLOR_RESET}"
  missing_required=1
fi

padded_code=$(printf "%-14s" "Code")
if have gh; then
  echo -e "   ${symbol_success} ${padded_code} ${COLOR_GRAY}→${COLOR_RESET} CLI (${COLOR_GREEN}gh${COLOR_RESET})"
elif mcp_present "github"; then
  echo -e "   ${symbol_warn} ${padded_code} ${COLOR_GRAY}→${COLOR_RESET} MCP fallback (${COLOR_YELLOW}github${COLOR_RESET}) — install gh CLI: ${COLOR_UNDERLINE}https://cli.github.com${COLOR_RESET}"
  mcp_used=1
else
  echo -e "   ${symbol_error} ${padded_code} ${COLOR_GRAY}→${COLOR_RESET} ${COLOR_RED}MISSING (REQUIRED)${COLOR_RESET}"
  echo -e "                  Install gh CLI: ${COLOR_UNDERLINE}https://cli.github.com${COLOR_RESET}${COLOR_GRAY}, then run ${COLOR_RESET}gh auth login"
  missing_required=1
fi

padded_wiki=$(printf "%-14s" "Wiki")
if mcp_present "confluence" || mcp_present "rovo"; then
  echo -e "   ${symbol_success} ${padded_wiki} ${COLOR_GRAY}→${COLOR_RESET} user-level MCP (${COLOR_GREEN}confluence/rovo${COLOR_RESET})"
else
  echo -e "   ${symbol_bullet} ${padded_wiki} ${COLOR_GRAY}→${COLOR_RESET} optional not found"
  echo -e "                  ${COLOR_GRAY}Allows access to: team docs + runbooks${COLOR_RESET}"
fi

if [ "$mcp_used" -eq 1 ]; then
  echo
  echo -e "   ${symbol_info} ${COLOR_YELLOW}CLIs use far fewer tokens than MCPs for the same tasks${COLOR_RESET}"
  echo -e "     ${COLOR_UNDERLINE}${CLI_PREFERRED_DOC}${COLOR_RESET}"
fi
echo

# 5) summary -----------------------------------------------------------------
echo -e " ${COLOR_BOLD}Step 5: Setup Summary${COLOR_RESET}"

if [ "$missing_required" -eq 1 ]; then
  echo -e "   ${symbol_warn} ${COLOR_YELLOW}Installation completed with warnings.${COLOR_RESET}"
  echo -e "     Some required companion integrations are missing (see above)."
  echo -e "     While ${COLOR_BOLD}ops-mcp${COLOR_RESET} itself will work and return resource handles,"
  echo -e "     your agent won't be able to query live logs, metrics, or code diffs."
  echo -e "     Please configure them when ready."
else
  echo -e "   ${symbol_success} ${COLOR_GREEN}Installation completed successfully!${COLOR_RESET}"
fi

echo -e "\n ${COLOR_BOLD}Quick Start:${COLOR_RESET}"
if [ -n "$ALIAS_RC" ]; then
  echo -e "   1. Activate the alias:"
  echo -e "      ${COLOR_CYAN}source $ALIAS_RC${COLOR_RESET}"
  echo -e "   2. Jump to your project and start Claude:"
  echo -e "      ${COLOR_CYAN}titanx && claude${COLOR_RESET}"
else
  echo -e "   1. Go to your project and start Claude:"
  echo -e "      ${COLOR_CYAN}cd \"$TARGET\" && claude${COLOR_RESET}"
fi
echo -e "   3. Sample questions to get started:"
echo -e "      ${COLOR_UNDERLINE}https://github.com/talk-to/ops-mcp#sample-questions-to-ask${COLOR_RESET}"

echo -e "\n ${COLOR_BOLD}Companion docs & setup:${COLOR_RESET}"
echo -e "   ${COLOR_UNDERLINE}https://github.com/talk-to/ops-mcp/tree/main#companion-mcps${COLOR_RESET}"
echo
