#!/usr/bin/env bash
# titanx installer — stand up the Titan Ops Console Claude project and audit
# the companion MCPs / CLIs that ops-mcp hands off to for live data.
#
# ops-mcp is a HOSTED HTTP MCP server (https://api.ops.flock.com/ops-mcp), so there is
# nothing to run locally — "installing" it means registering that endpoint, which the
# scaffolded project's .mcp.json does. This script:
#   1. scaffolds the ops console project (from the bundled template) into TARGET_DIR,
#   2. checks the ops-mcp endpoint is reachable,
#   3. audits each companion: MCP preferred, CLI accepted as fallback — flags if neither.
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

if have npx; then
  echo -e "   ${symbol_success} npx detected ${COLOR_GRAY}(required for Sentry + Kubernetes MCP)${COLOR_RESET}"
else
  echo -e "   ${symbol_error} npx not found ${COLOR_GRAY}(required for Sentry + Kubernetes MCP)${COLOR_RESET}"
  echo -e "     ${COLOR_RED}Install Node.js: ${COLOR_UNDERLINE}https://nodejs.org${COLOR_RESET}"
fi

if have uvx; then
  echo -e "   ${symbol_success} uvx detected ${COLOR_GRAY}(required for Grafana MCP)${COLOR_RESET}"
else
  echo -e "   ${symbol_error} uvx not found ${COLOR_GRAY}(required for Grafana MCP)${COLOR_RESET}"
  echo -e "     ${COLOR_RED}Install uv: ${COLOR_UNDERLINE}curl -LsSf https://astral.sh/uv/install.sh | sh${COLOR_RESET}"
fi
echo

# 4) companion audit ---------------------------------------------------------
# For each companion: MCP is preferred; CLI is accepted as fallback.
# REQUIRED companions must have at least one configured.
missing_required=0
audit_companion(){ # label  mcp_name  cli_name  REQUIRED|optional  description
  local label="$1" mcp="$2" cli="$3" req="$4" desc="$5"
  local padded_label
  padded_label=$(printf "%-14s" "$label")

  if mcp_present "$mcp"; then
    echo -e "   ${symbol_success} ${padded_label} ${COLOR_GRAY}→${COLOR_RESET} Using MCP (${COLOR_GREEN}$mcp${COLOR_RESET})"
  elif have "$cli"; then
    echo -e "   ${symbol_warn} ${padded_label} ${COLOR_GRAY}→${COLOR_RESET} Using CLI fallback (${COLOR_YELLOW}$cli${COLOR_RESET})"
    echo -e "                  ${COLOR_GRAY}* Note: MCP ($mcp) is preferred for richer context.${COLOR_RESET}"
  elif [ "$req" = REQUIRED ]; then
    echo -e "   ${symbol_error} ${padded_label} ${COLOR_GRAY}→${COLOR_RESET} ${COLOR_RED}MISSING (REQUIRED)${COLOR_RESET}"
    echo -e "                  Configure MCP '${COLOR_BOLD}$mcp${COLOR_RESET}' or install CLI '${COLOR_BOLD}$cli${COLOR_RESET}'"
    echo -e "                  Purpose: $desc"
    missing_required=1
  else
    echo -e "   ${symbol_bullet} ${padded_label} ${COLOR_GRAY}→${COLOR_RESET} Optional not found"
    echo -e "                  ${COLOR_GRAY}Allows access to: $desc${COLOR_RESET}"
  fi
}

echo -e " ${COLOR_BOLD}Step 4: Auditing Companion Integrations${COLOR_RESET}"
echo -e "   ${COLOR_GRAY}Bundled MCPs ship with this project. Others require manual setup.${COLOR_RESET}\n"

echo -e "   ${COLOR_GRAY}Bundled (in .mcp.json):${COLOR_RESET}"
echo -e "   ${symbol_success} $(printf "%-14s" "Observability") ${COLOR_GRAY}→${COLOR_RESET} Bundled MCP (${COLOR_GREEN}grafana${COLOR_RESET})"
echo -e "   ${symbol_success} $(printf "%-14s" "Error Tracking") ${COLOR_GRAY}→${COLOR_RESET} Bundled MCP (${COLOR_GREEN}sentry${COLOR_RESET})"
echo -e "   ${symbol_success} $(printf "%-14s" "Orchestration") ${COLOR_GRAY}→${COLOR_RESET} Bundled MCP (${COLOR_GREEN}kubernetes${COLOR_RESET})"
echo
echo -e "   ${COLOR_GRAY}Requires manual setup:${COLOR_RESET}"
padded_code=$(printf "%-14s" "Code")
if have gh; then
  echo -e "   ${symbol_success} ${padded_code} ${COLOR_GRAY}→${COLOR_RESET} Using CLI (${COLOR_GREEN}gh${COLOR_RESET})"
elif mcp_present "github"; then
  echo -e "   ${symbol_warn} ${padded_code} ${COLOR_GRAY}→${COLOR_RESET} Using MCP fallback (${COLOR_YELLOW}github${COLOR_RESET})"
  echo -e "                  ${COLOR_GRAY}* Note: gh CLI is preferred — run ${COLOR_RESET}gh auth login${COLOR_GRAY} after install.${COLOR_RESET}"
else
  echo -e "   ${symbol_error} ${padded_code} ${COLOR_GRAY}→${COLOR_RESET} ${COLOR_RED}MISSING (REQUIRED)${COLOR_RESET}"
  echo -e "                  Install gh CLI: ${COLOR_UNDERLINE}https://cli.github.com${COLOR_RESET}${COLOR_GRAY}, then run ${COLOR_RESET}gh auth login"
  missing_required=1
fi
audit_companion "Wiki"         confluence rovo        optional "team docs + runbooks"
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
