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
#      Grafana: grafana MCP (uvx mcp-grafana) preferred; gcx CLI accepted as fallback
#      Sentry:  sentry MCP (@sentry/mcp-server) preferred; sentry CLI accepted as fallback
#      Kubernetes + GitHub: kubectl / gh; MCP accepted as fallback.
#
# Usage:
#   ./install.sh [TARGET_DIR] [-f|--force]
#     TARGET_DIR   where to create the project (default: ~/titanx)
#     -f, --force  overwrite template-managed files if the dir already exists
set -euo pipefail

OPS_MCP_URL="https://api.ops.flock.com/ops-mcp"
S3_BASE="https://s3browser.ops.riva.co/titan-logs-use/titanx"

# --- Static URLs (update here; do not hardcode elsewhere) ---
GRAFANA_ENDPOINT="https://grafana.eks.ops.titan.email"
SENTRY_ENDPOINT="https://sentry.eks.ops.titan.email"
SENTRY_HOST="sentry.eks.ops.titan.email"  # hostname only — used in sentry MCP config (no scheme)

URL_GCX="https://github.com/grafana/gcx"
URL_SENTRY_CLI="https://cli.sentry.dev"
URL_KUBECTL="https://kubernetes.io/docs/tasks/tools"
URL_GH_CLI="https://cli.github.com"

URL_AGENT_CLAUDE="https://claude.ai/code"
URL_AGENT_OPENCODE="https://opencode.ai"
URL_AGENT_CODEX="https://chatgpt.com/codex"
URL_AGENT_AGY="https://antigravity.google"

URL_CLI_PREFERRED_DOC="https://www.anthropic.com/engineering/code-execution-with-mcp"
URL_SAMPLE_QUESTIONS="https://github.com/talk-to/ops-mcp/blob/main/docs/SampleQuestions.md"
URL_COMPANION_DOCS="https://github.com/talk-to/ops-mcp/tree/main#companion-tools"
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
COLOR_BOLD=$'\e[1m'
COLOR_DIM=$'\e[2m'
COLOR_UNDERLINE=$'\e[4m'
COLOR_RESET=$'\e[0m'

COLOR_GREEN=$'\e[38;5;84m'     # Vibrant pastel green
COLOR_YELLOW=$'\e[38;5;220m'   # Warm gold/yellow
COLOR_RED=$'\e[38;5;203m'      # Warm pastel red
COLOR_CYAN=$'\e[38;5;86m'       # Turquoise/Cyan
COLOR_BLUE=$'\e[38;5;39m'       # Vivid deep blue
COLOR_PURPLE=$'\e[38;5;141m'   # Soft purple/magenta
COLOR_GRAY=$'\e[38;5;244m'     # Neutral gray

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

# Fetch the Claude user-level MCP list in the background early (major speedup).
# Claude Code-specific: used to detect MCP fallbacks for companion tools.
# Non-Claude agents configure their own MCPs separately; mcp_present() returns
# false for those installs, so MCP fallback suggestions are skipped.
MCP_LIST_FILE="/tmp/claude_mcp_list_$$"
CLAUDE_MCP_PID=""
if have claude; then
  CLEANUP_FILES+=("$MCP_LIST_FILE")
  claude mcp list 2>/dev/null > "$MCP_LIST_FILE" &
  CLAUDE_MCP_PID=$!
fi

CODEX_MCP_LIST_FILE="/tmp/codex_mcp_list_$$"
CODEX_MCP_PID=""
if have codex; then
  CLEANUP_FILES+=("$CODEX_MCP_LIST_FILE")
  codex mcp list 2>/dev/null > "$CODEX_MCP_LIST_FILE" &
  CODEX_MCP_PID=$!
fi

OPENCODE_MCP_LIST_FILE="/tmp/opencode_mcp_list_$$"
OPENCODE_MCP_PID=""
if have opencode; then
  CLEANUP_FILES+=("$OPENCODE_MCP_LIST_FILE")
  opencode mcp list 2>/dev/null > "$OPENCODE_MCP_LIST_FILE" &
  OPENCODE_MCP_PID=$!
fi

# mcp_present checks the user-level MCP list (captured at startup).
# Scoped to Claude, Codex, and OpenCode; for other agents (like agy), we fall back to writing
# to project-level config so the project is self-contained out-of-the-box.
mcp_present(){
  if [ "${SELECTED_AGENT:-}" = "claude" ]; then
    if [ -n "$CLAUDE_MCP_PID" ]; then
      wait "$CLAUDE_MCP_PID" 2>/dev/null || true
      CLAUDE_MCP_PID=""
    fi
    if [ -f "$MCP_LIST_FILE" ]; then
      grep -qiw "$1" "$MCP_LIST_FILE"
    else
      return 1
    fi
  elif [ "${SELECTED_AGENT:-}" = "codex" ]; then
    if [ -n "$CODEX_MCP_PID" ]; then
      wait "$CODEX_MCP_PID" 2>/dev/null || true
      CODEX_MCP_PID=""
    fi
    if [ -f "$CODEX_MCP_LIST_FILE" ]; then
      grep -qiw "$1" "$CODEX_MCP_LIST_FILE"
    else
      return 1
    fi
  elif [ "${SELECTED_AGENT:-}" = "opencode" ]; then
    if [ -n "$OPENCODE_MCP_PID" ]; then
      wait "$OPENCODE_MCP_PID" 2>/dev/null || true
      OPENCODE_MCP_PID=""
    fi
    if [ -f "$OPENCODE_MCP_LIST_FILE" ]; then
      grep -qiw "$1" "$OPENCODE_MCP_LIST_FILE"
    else
      return 1
    fi
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

# write_project_mcp_json writes the project .mcp.json.
# Always includes ops-mcp. When add_grafana=1 or add_sentry=1, also injects
# those MCP entries — used when neither the user-level MCP nor the CLI fallback
# is present, so the project is self-contained out of the box.
write_project_mcp_json(){
  local path="$1" add_grafana="${2:-0}" add_sentry="${3:-0}"

  # Build optional server blocks
  local extra_servers=""

  if [ "$add_grafana" -eq 1 ]; then
    local grafana_token
    if [ -n "$TITANX_GRAFANA_TOKEN" ]; then
      grafana_token="$TITANX_GRAFANA_TOKEN"
    else
      grafana_token="<ask in #devops-tooling>"
    fi
    extra_servers="${extra_servers},
    \"grafana\": {
      \"command\": \"uvx\",
      \"args\": [
        \"mcp-grafana\"
      ],
      \"env\": {
        \"GRAFANA_URL\": \"${GRAFANA_ENDPOINT}\",
        \"GRAFANA_SERVICE_ACCOUNT_TOKEN\": \"${grafana_token}\"
      }
    }"
  fi

  if [ "$add_sentry" -eq 1 ]; then
    local sentry_token
    if [ -n "$TITANX_SENTRY_TOKEN" ]; then
      sentry_token="$TITANX_SENTRY_TOKEN"
    else
      sentry_token="<ask in #devops-tooling>"
    fi
    extra_servers="${extra_servers},
    \"sentry\": {
      \"command\": \"npx\",
      \"args\": [
        \"-y\",
        \"@sentry/mcp-server@latest\"
      ],
      \"env\": {
        \"SENTRY_HOST\": \"${SENTRY_HOST}\",
        \"SENTRY_ACCESS_TOKEN\": \"${sentry_token}\"
      }
    }"
  fi

  printf '{
  "mcpServers": {
    "ops-mcp": {
      "type": "http",
      "url": "%s"
    }%s
  }
}
' "$OPS_MCP_URL" "$extra_servers" > "$path"
}

# write_project_codex_toml writes the project .codex/config.toml.
# Injects ops-mcp, and optionally grafana/sentry MCP server configs in TOML format.
write_project_codex_toml(){
  local path="$1" add_grafana="${2:-0}" add_sentry="${3:-0}"
  mkdir -p "$(dirname "$path")"

  {
    printf '[mcp_servers.ops-mcp]\nurl = "%s"\n' "$OPS_MCP_URL"

    if [ "$add_grafana" -eq 1 ]; then
      local grafana_token
      if [ -n "$TITANX_GRAFANA_TOKEN" ]; then
        grafana_token="$TITANX_GRAFANA_TOKEN"
      else
        grafana_token="<ask in #devops-tooling>"
      fi
      printf '\n[mcp_servers.grafana]\ncommand = "uvx"\nargs = [\n  "mcp-grafana"\n]\nenv = { GRAFANA_URL = "%s", GRAFANA_SERVICE_ACCOUNT_TOKEN = "%s" }\n' "$GRAFANA_ENDPOINT" "$grafana_token"
    fi

    if [ "$add_sentry" -eq 1 ]; then
      local sentry_token
      if [ -n "$TITANX_SENTRY_TOKEN" ]; then
        sentry_token="$TITANX_SENTRY_TOKEN"
      else
        sentry_token="<ask in #devops-tooling>"
      fi
      printf '\n[mcp_servers.sentry]\ncommand = "npx"\nargs = [\n  "-y",\n  "@sentry/mcp-server@latest"\n]\nenv = { SENTRY_HOST = "%s", SENTRY_ACCESS_TOKEN = "%s" }\n' "$SENTRY_HOST" "$sentry_token"
    fi
  } > "$path"
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
      printf '# gcx (Grafana CLI): %s\n' "$URL_GCX"
      printf 'GRAFANA_URL=%s\n' "$GRAFANA_ENDPOINT"
      if [ -n "$TITANX_GRAFANA_TOKEN" ]; then
        printf 'GRAFANA_TOKEN=%s\n' "$TITANX_GRAFANA_TOKEN"
      else
        printf '#GRAFANA_TOKEN=<unavailable — ask in #devops-tooling>\n'
      fi
    fi
    if [ "$inc_sentry" -eq 1 ]; then
      printf '# sentry CLI: %s\n' "$URL_SENTRY_CLI"
      printf 'SENTRY_URL=%s\n' "$SENTRY_ENDPOINT"
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

# TITANX_AGENTS: ordered list of supported AI agents (binary:label pairs).
TITANX_AGENTS=(
  "claude:Claude Code"
  "opencode:OpenCode"
  "codex:OpenAI Codex"
  "agy:Antigravity"
)

# select_agent prompts the user to pick an AI agent from those available in PATH.
# Sets SELECTED_AGENT to the chosen binary name. Exits if none are installed.
SELECTED_AGENT=""
AGENT_AUTOSELECTED=0
select_agent() {
  local current="${1:-}"
  local entries=() labels=() installed=()
  local total_installed=0
  local first_installed=""

  for pair in "${TITANX_AGENTS[@]}"; do
    local bin="${pair%%:*}" label="${pair#*:}"
    entries+=("$bin")
    labels+=("$label")
    if have "$bin"; then
      installed+=(1)
      total_installed=$((total_installed + 1))
      if [ -z "$first_installed" ]; then
        first_installed="$bin"
      fi
    else
      installed+=(0)
    fi
  done

  if [ "$total_installed" -eq 0 ]; then
    echo -e "   ${symbol_error} ${COLOR_RED}No supported AI agent found in PATH.${COLOR_RESET}"
    echo -e "     Install one of: claude, opencode, codex, agy — then re-run install.sh"
    exit 1
  fi

  if [ "$total_installed" -eq 1 ] && [ -z "$current" ]; then
    SELECTED_AGENT="$first_installed"
    AGENT_AUTOSELECTED=1
    echo -e "   ${symbol_success} AI agent: ${COLOR_CYAN}${SELECTED_AGENT}${COLOR_RESET} ${COLOR_GRAY}(only available agent)${COLOR_RESET}"
    echo
    return
  fi

  echo -e "   ${COLOR_BOLD}Select AI Agent:${COLOR_RESET}"
  for idx in "${!entries[@]}"; do
    local bin="${entries[$idx]}" label="${labels[$idx]}" is_inst="${installed[$idx]}"
    local marker="    "
    if [ "$bin" = "$current" ]; then
      marker="  ${COLOR_PURPLE}➜${COLOR_RESET} "
    fi
    
    if [ "$is_inst" -eq 1 ]; then
      printf "     %s%d) %-12s ${COLOR_RESET}%s\n" "$marker" "$(( idx + 1 ))" "$bin" "$label"
    else
      printf "     %s${COLOR_GRAY}%d) %-12s %s (not installed)${COLOR_RESET}\n" "$marker" "$(( idx + 1 ))" "$bin" "$label"
    fi
  done

  while true; do
    printf "     ${COLOR_GRAY}Press number to select❯${COLOR_RESET} "
    local choice
    read -r choice </dev/tty
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#entries[@]}" ]; then
      local selected_idx=$((choice-1))
      if [ "${installed[$selected_idx]}" -eq 1 ]; then
        SELECTED_AGENT="${entries[$selected_idx]}"
        break
      else
        echo -e "     ${COLOR_RED}Agent '${entries[$selected_idx]}' is not installed. Please choose an installed agent.${COLOR_RESET}"
      fi
    else
      # Default fallback
      if [ -n "$current" ] && have "$current"; then
        SELECTED_AGENT="$current"
      else
        SELECTED_AGENT="$first_installed"
      fi
      break
    fi
  done
  echo
}

# write_agent_conf writes/updates AGENT and tokens in conf.txt.
write_agent_conf() {
  local agent="$1" conf="$HOME/.titanx/conf.txt"
  if [ -f "$conf" ]; then
    local tmp; tmp="$(mktemp)"
    grep -v -e '^AGENT=' -e '^GRAFANA_TOKEN=' -e '^SENTRY_TOKEN=' "$conf" > "$tmp" || true
    printf 'AGENT=%s\n' "$agent" >> "$tmp"
    if [ -n "${TITANX_GRAFANA_TOKEN:-}" ]; then
      printf 'GRAFANA_TOKEN=%s\n' "$TITANX_GRAFANA_TOKEN" >> "$tmp"
    fi
    if [ -n "${TITANX_SENTRY_TOKEN:-}" ]; then
      printf 'SENTRY_TOKEN=%s\n' "$TITANX_SENTRY_TOKEN" >> "$tmp"
    fi
    cat "$tmp" > "$conf"; rm -f "$tmp"
  fi
}

# set_titanx_function writes the titanx shell function to a script and sources it in user's rc file.
set_titanx_function() {
  local target="$TARGET" titanx_dir="$HOME/.titanx"
  case "${SHELL##*/}" in
    zsh)  ALIAS_RC="$HOME/.zshrc" ;;
    bash) ALIAS_RC="$HOME/.bashrc" ;;
    *)
      echo -e "   ${symbol_warn} Shell not supported automatically. Please add titanx() manually."
      return ;;
  esac

  # Write the titanx.sh script to ~/.titanx/
  mkdir -p "$titanx_dir"
  cat > "$titanx_dir/titanx.sh" << 'SH_EOF'
# titanx shell integration — sourced from shell RC

# Determine directory of this sourced script dynamically
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _TITANX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _TITANX_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
  _TITANX_DIR=""
fi

# Color definitions (same palette as install.sh)
COLOR_RESET=$'\e[0m'
COLOR_BOLD=$'\e[1m'
COLOR_GREEN=$'\e[38;5;84m'
COLOR_YELLOW=$'\e[38;5;220m'
COLOR_RED=$'\e[38;5;203m'
COLOR_GRAY=$'\e[38;5;244m'

titanx() {
  local DIR="${_TITANX_DIR:-}"
  if [ -z "$DIR" ]; then
    echo "Error: Could not resolve titanx project directory." >&2
    return 1
  fi
  local PROJECT_DIR="$(cat "$DIR/project" 2>/dev/null || echo "$HOME/titanx")"
  local CONF="$DIR/conf.txt"
  local agent model version last_updated

  # read conf
  agent=$(grep '^AGENT=' "$CONF" 2>/dev/null | cut -d= -f2)
  model=$(grep '^MODEL=' "$CONF" 2>/dev/null | cut -d= -f2)
  version=$(cat "$DIR/version.txt" 2>/dev/null | tr -d '[:space:]')
  last_updated=$(grep '^LAST_UPDATED=' "$CONF" 2>/dev/null | cut -d= -f2-)
  agent=${agent:-claude}

  case "${1:-}" in
    -h|--help)
      echo ""
      echo "  titanx — Titan Ops Console"
      echo ""
      echo "  Usage:"
      echo "    titanx                   open project with ${agent}"
      echo "    titanx -a/--agent        switch AI agent"
      echo "    titanx -u/--update       manually pull latest template from S3"
      echo "    titanx -i/--info         show version, agent, and last update time"
      echo "    titanx -x/--uninstall    remove titanx from this system"
      echo "    titanx -d/--doctor       diagnose and check integrations"
      echo "    titanx -h/--help         show this help"
      echo ""
      ;;
    -i|--info)
      echo ""
      echo "  titanx info"
      echo ""
      printf "  ${COLOR_BOLD}%-10s${COLOR_RESET} %s\n" "Version" "${version:-(unknown)}"
      printf "  ${COLOR_BOLD}%-10s${COLOR_RESET} %s\n" "Agent"   "$agent"
      printf "  ${COLOR_BOLD}%-10s${COLOR_RESET} %s\n" "Updated" "${last_updated:-(never)}"
      printf "  ${COLOR_BOLD}%-10s${COLOR_RESET} %s\n" "Project" "$PROJECT_DIR"
      echo ""
      ;;
    -u|--update)
      echo "  Updating titanx..."
      (cd "$DIR" && bash update.sh --force)
      echo "  Done."
      ;;
    -a|--agent)
      echo ""
      local _total_installed=0 _first_installed=""
      local _pair _bin _lbl _marker _is_inst

      for _pair in "claude:Claude Code" "opencode:OpenCode" "codex:OpenAI Codex" "agy:Antigravity"; do
        _bin="${_pair%%:*}"
        if command -v "$_bin" >/dev/null 2>&1; then
          _total_installed=$((_total_installed + 1))
          if [ -z "$_first_installed" ]; then
            _first_installed="$_bin"
          fi
        fi
      done

      if [ "$_total_installed" -eq 0 ]; then
        echo "  No supported AI agent found in PATH."
        echo "  Install one of: claude, opencode, codex, agy"
        echo ""
        return 1
      fi

      echo "  Select AI agent:"
      local _i=1
      for _pair in "claude:Claude Code" "opencode:OpenCode" "codex:OpenAI Codex" "agy:Antigravity"; do
        _bin="${_pair%%:*}"
        _lbl="${_pair#*:}"
        _marker="    "
        if [ "$_bin" = "$agent" ]; then
          _marker="➜   "
        fi
        
        if command -v "$_bin" >/dev/null 2>&1; then
          printf "   %s%d) %-12s %s\n" "$_marker" "$_i" "$_bin" "$_lbl"
        else
          printf "   %s${COLOR_GRAY}%d) %-12s %s (not installed)${COLOR_RESET}\n" "$_marker" "$_i" "$_bin" "$_lbl"
        fi
        _i=$((_i + 1))
      done

      while true; do
        printf "   Press number to select❯ "
        local _choice; read -r _choice
        case "$_choice" in
          *[!0-9]*|"")
            echo "  No change."
            break
            ;;
          *)
            if [ "$_choice" -ge 1 ] && [ "$_choice" -le 4 ]; then
              local _curr_idx=1 _new="" _new_installed=0
              for _pair in "claude:Claude Code" "opencode:OpenCode" "codex:OpenAI Codex" "agy:Antigravity"; do
                if [ "$_curr_idx" -eq "$_choice" ]; then
                  _new="${_pair%%:*}"
                  if command -v "$_new" >/dev/null 2>&1; then
                    _new_installed=1
                  fi
                  break
                fi
                _curr_idx=$((_curr_idx + 1))
              done

              if [ "$_new_installed" -eq 1 ]; then
                if [ -f "$CONF" ]; then
                  local _tmp; _tmp=$(mktemp)
                  grep -v '^AGENT=' "$CONF" > "$_tmp" || true
                  printf 'AGENT=%s\n' "$_new" >> "$_tmp"
                  cat "$_tmp" > "$CONF"; rm -f "$_tmp"
                fi
                echo "  Agent set to: $_new"
                echo "  Reconfiguring companion integrations..."
                bash "$DIR/configure.sh"
                break
              else
                echo "  Agent '$_new' is not installed. Please choose an installed agent."
              fi
            else
              echo "  No change."
              break
            fi
            ;;
        esac
      done
      echo ""
      ;;
    -d|--doctor)
      bash "$DIR/doctor.sh"
      ;;
    -x|--uninstall)
      echo ""
      echo "  Uninstalling titanx..."
      
      # 1) Clean up shell integrations from all common shell config files
      local rc_files=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
      for rc in "${rc_files[@]}"; do
        if [ -f "$rc" ]; then
          local tmp; tmp=$(mktemp)
          awk '
            /titanx\.sh/ { next }
            /# titanx shell integration/ { next }
            /^titanx\(\)/ { skip=1 }
            skip && /^\}/ { skip=0; next }
            skip { next }
            { print }
          ' "$rc" > "$tmp"
          cat "$tmp" > "$rc"; rm -f "$tmp"
          echo "  Cleaned shell integrations from $rc"
        fi
      done

      # 2) Resolve project directory from ~/.titanx/project before deleting it
      local proj_dir=""
      if [ -f "$HOME/.titanx/project" ]; then
        proj_dir=$(cat "$HOME/.titanx/project" | tr -d '[:space:]')
      fi
      proj_dir=${proj_dir:-$HOME/titanx}

      # 3) Remove directories
      if [ -d "$proj_dir" ]; then
        rm -rf "$proj_dir"
        echo "  Removed project directory: $proj_dir"
      fi
      if [ -d "$HOME/.titanx" ]; then
        rm -rf "$HOME/.titanx"
        echo "  Removed configuration directory: ~/.titanx"
      fi

      echo "  titanx uninstalled. Restart your shell or run: exec ${SHELL##*/}"
      echo ""
      ;;
    *)
      if [ -n "${1:-}" ]; then
        echo "Unknown option: $1"
        titanx -h
      else
        # Auto-update: check S3 for a new version if last check was >5 min ago.
        # Works for all agents — no longer depends on Claude's UserPromptSubmit hook.
        local _lock="$DIR/.update.conf" _now _last _interval=300
        _now=$(date +%s)
        _last=0
        [ -f "$_lock" ] && read -r _last _ < "$_lock" 2>/dev/null || true
        if (( _now - _last >= _interval )); then
          (exec bash "$DIR/update.sh" >/dev/null 2>&1 &)
        fi
        cd "$PROJECT_DIR" && "$agent" ${model:+--model "$model"}
      fi
      ;;
  esac
}
SH_EOF

  local tmp; tmp="$(mktemp)"
  # Strip any previous titanx alias, function block, or titanx.sh source lines
  awk '
    /^alias titanx=/ { next }
    /titanx\.sh/ { next }
    /^titanx\(\)/ { skip=1 }
    skip && /^\}/ { skip=0; next }
    skip { next }
    { print }
  ' "$ALIAS_RC" 2>/dev/null > "$tmp" || true

  # Append shell integration sourcing line
  cat >> "$tmp" << FUNCEOF

# titanx shell integration
[ -f "$HOME/.titanx/titanx.sh" ] && source "$HOME/.titanx/titanx.sh" || true
FUNCEOF

  cat "$tmp" > "$ALIAS_RC"; rm "$tmp"

  # Write project path so titanx() can resolve the project directory
  echo "$TARGET" > "$titanx_dir/project"
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
mkdir -p "$TARGET"
if cp -R "$TEMPLATE/." "$TARGET/"; then
  echo -e "   ${symbol_success} Scaffolded ops console into: ${COLOR_CYAN}$TARGET${COLOR_RESET}"
else
  echo -e "   ${symbol_error} Failed to copy template files to $TARGET"
  exit 1
fi
echo

# 1b) separate operational files into ~/.titanx --------------------------------
TITANX_DOTDIR="$HOME/.titanx"
mkdir -p "$TITANX_DOTDIR"
for f in update.sh doctor.sh configure.sh conf.txt manifest.txt version.txt; do
  if [ -f "$TARGET/$f" ]; then
    if [ "$f" = "conf.txt" ] && [ -f "$TITANX_DOTDIR/conf.txt" ]; then
      rm "$TARGET/$f"
    else
      cp "$TARGET/$f" "$TITANX_DOTDIR/$f"
      rm "$TARGET/$f"
    fi
  fi
done

# 2) agent selection + shell function -----------------------------------------
echo -e " ${COLOR_BOLD}Step 2: AI Agent & Shell Integration${COLOR_RESET}"

# Read current agent from conf.txt if it exists (re-install / --force case)
current_agent=""
if [ -f "$HOME/.titanx/conf.txt" ]; then
  current_agent=$(grep '^AGENT=' "$HOME/.titanx/conf.txt" 2>/dev/null | cut -d= -f2)
fi

select_agent "$current_agent"
write_agent_conf "$SELECTED_AGENT"

set_titanx_function
if [ -n "$ALIAS_RC" ]; then
  if [ "$AGENT_AUTOSELECTED" -eq 0 ]; then
    echo -e "   ${symbol_success} Agent ${COLOR_CYAN}${SELECTED_AGENT}${COLOR_RESET} selected"
  fi
  echo -e "   ${symbol_success} Registered ${COLOR_CYAN}titanx${COLOR_RESET} function in ${COLOR_CYAN}$ALIAS_RC${COLOR_RESET}"
  echo -e "     ${COLOR_GRAY}You can now run: ${COLOR_RESET}source $ALIAS_RC${COLOR_GRAY} (or open a new terminal)${COLOR_RESET}"
fi
echo

# 3) preflight ----------------------------------------------------------------
echo -e " ${COLOR_BOLD}Step 3: Preflight Checks${COLOR_RESET}"
agent_install_url() {
  case "$1" in
    claude)   echo "$URL_AGENT_CLAUDE" ;;
    opencode) echo "$URL_AGENT_OPENCODE" ;;
    codex)    echo "$URL_AGENT_CODEX" ;;
    agy)      echo "$URL_AGENT_AGY" ;;
    *)        echo "" ;;
  esac
}
if have "$SELECTED_AGENT"; then
  echo -e "   ${symbol_success} ${SELECTED_AGENT} detected"
else
  url=$(agent_install_url "$SELECTED_AGENT")
  echo -e "   ${symbol_error} ${SELECTED_AGENT} not found"
  if [ -n "$url" ]; then
    echo -e "     ${COLOR_RED}Please install it: ${COLOR_UNDERLINE}${url}${COLOR_RESET}"
  fi
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
fetch_tokens
write_agent_conf "$SELECTED_AGENT"

echo -e " ${COLOR_BOLD}Step 4: Auditing Companion Integrations${COLOR_RESET}"
missing_required=0
bash "$TITANX_DOTDIR/configure.sh" || missing_required=1
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
  echo -e "   1. Activate the shell function:"
  echo -e "      ${COLOR_CYAN}source $ALIAS_RC${COLOR_RESET}"
  echo -e "   2. Open titanx:"
  echo -e "      ${COLOR_CYAN}titanx${COLOR_RESET}"
  echo -e "   3. Sample questions to get started:"
  echo -e "      ${COLOR_UNDERLINE}${URL_SAMPLE_QUESTIONS}${COLOR_RESET}"
else
  echo -e "   1. Go to your project and start ${SELECTED_AGENT}:"
  echo -e "      ${COLOR_CYAN}cd \"$TARGET\" && ${SELECTED_AGENT}${COLOR_RESET}"
  echo -e "   2. Sample questions to get started:"
  echo -e "      ${COLOR_UNDERLINE}${URL_SAMPLE_QUESTIONS}${COLOR_RESET}"
fi

echo -e "\n ${COLOR_BOLD}Companion docs & setup:${COLOR_RESET}"
echo -e "   ${COLOR_UNDERLINE}${URL_COMPANION_DOCS}${COLOR_RESET}"
echo
