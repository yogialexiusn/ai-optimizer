#!/usr/bin/env bash
# Setup RTK, optional ICM or Mem0 memory, and optional QMD or Graphify for AI agent token optimization.
# Run from the project root (where .git / docs / AGENTS.md live).
#
# Cursor / Cursor CLI:
#   ICM  — MCP (~/.cursor/mcp.json) + rule (~/.cursor/rules/icm.mdc); local SQLite, no account
#   Mem0 — MCP (~/.cursor/mcp.json) + rule (~/.cursor/rules/mem0.mdc); cloud, requires API key
#
# Optional env (non-interactive):
#   AGENT=cursor|github-copilot|antigravity
#   MEMORY_TOOL=icm|mem0|none    — icm: local memory; mem0: cloud memory (needs MEM0_API_KEY)
#   DOCS_TOOL=qmd|graphify|none  — qmd: semantic search over docs/**/*.md; graphify: knowledge graph + MCP for larger repos
#   BUILD_GRAPHIFY=yes|no        — when DOCS_TOOL=graphify, build graphify-out/graph.json during setup
#   GRAPHIFY_MCP=yes|no          — graphifyy[mcp] (Cursor query_graph) vs CLI-only graphifyy
#   AUTO_INSTALL_PREREQS=yes|no  — approve all system prerequisite installs
#   INSTALL_NODEJS=yes|no        — Node.js 22+ via package manager (sudo; required for QMD)
#   INSTALL_APT_PACKAGES=yes|no  — apt packages such as pipx (sudo)
#   ALLOW_SUDO=yes|no            — sudo for npm global installs / permission fixes
#   SKIP_AGENT_CHECK=yes|no      — skip Cursor/Copilot/Antigravity install verification (e.g. Docker)
#   MEM0_API_KEY=m0-...          — Mem0 Platform API key (https://app.mem0.ai); only when MEMORY_TOOL=mem0
# Back-compat: ENABLE_ICM=yes|no or ENABLE_MEM0=yes|no map to MEMORY_TOOL when MEMORY_TOOL is unset
set -e

# -------------------------------
# PERMISSION HELPERS
# -------------------------------

is_interactive() {
  [[ -t 0 ]]
}

env_is_yes() {
  case "${1:-}" in
    yes|Yes|YES|y|Y|1|true|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

env_is_no() {
  case "${1:-}" in
    no|No|NO|n|N|0|false|FALSE) return 0 ;;
    *) return 1 ;;
  esac
}

# ask_permission "description" [ENV_VAR]
# Returns 0 if approved. Honors ENV_VAR, then AUTO_INSTALL_PREREQS, then interactive prompt.
ask_permission() {
  local description="$1"
  local env_var="${2:-}"

  if [[ -n "$env_var" ]]; then
    local env_val="${!env_var:-}"
    if env_is_yes "$env_val"; then
      return 0
    fi
    if env_is_no "$env_val"; then
      return 1
    fi
  fi

  if [[ -n "${AUTO_INSTALL_PREREQS:-}" ]]; then
    if env_is_yes "${AUTO_INSTALL_PREREQS}"; then
      return 0
    fi
    if env_is_no "${AUTO_INSTALL_PREREQS}"; then
      return 1
    fi
  fi

  if ! is_interactive; then
    echo "❌ Permission required (non-interactive): ${description}"
    if [[ -n "$env_var" ]]; then
      echo "   Set ${env_var}=yes or AUTO_INSTALL_PREREQS=yes, then re-run."
    else
      echo "   Set AUTO_INSTALL_PREREQS=yes, then re-run."
    fi
    return 1
  fi

  echo ""
  echo "🔐 Permission required: ${description}"
  select _choice in "No" "Yes"; do
    case "$_choice" in
      Yes) return 0 ;;
      No)  return 1 ;;
    esac
  done
}

sudo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return $?
  fi
  if ! command -v sudo &> /dev/null; then
    echo "❌ sudo is required but not installed."
    return 1
  fi
  sudo "$@"
}

ensure_path_contains() {
  local dir="$1"
  if [ -n "$dir" ] && [ -d "$dir" ] && [[ ":$PATH:" != *":$dir:"* ]]; then
    export PATH="${dir}:$PATH"
  fi
}

# RTK, Graphify, and Antigravity CLI install into ~/.local/bin.
ensure_local_bin_on_path() {
  ensure_path_contains "$HOME/.local/bin"
}

require_command() {
  local cmd="$1"
  local hint="$2"
  ensure_local_bin_on_path
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ ${cmd} not found on PATH."
    echo "   ${hint}"
    exit 1
  fi
}

ensure_agent_home_dirs() {
  mkdir -p "$HOME/.local/bin"

  # RTK writes state under ~/.config/rtk. Docker bind-mounts (e.g. auth.json →
  # ~/.config/cursor/auth.json) often create ~/.config as root-owned; fix that.
  ensure_config_dir_writable

  case "$AGENT" in
    cursor|github-copilot)
      mkdir -p "$HOME/.cursor/rules"
      # RTK global Cursor init still writes Claude awareness files under ~/.claude
      # on fresh machines; create it so rtk init does not fail (rtk-ai/rtk#1465).
      mkdir -p "$HOME/.claude"
      ;;
    antigravity)
      mkdir -p "$HOME/.gemini"
      ;;
  esac
}

ensure_config_dir_writable() {
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"

  if [[ ! -d "$config_dir" ]]; then
    mkdir -p "$config_dir"
  fi

  if [[ -w "$config_dir" ]]; then
    mkdir -p "${config_dir}/rtk"
    return 0
  fi

  echo "⚠️ ${config_dir} is not writable by $(whoami) (common with Docker file bind-mounts)."
  if ask_permission "Fix ownership of ${config_dir}? (requires sudo)" "ALLOW_SUDO"; then
    echo "🔧 Fixing ownership of ${config_dir}..."
    sudo_cmd chown -R "$(id -u):$(id -g)" "$config_dir"
  fi

  if [[ ! -w "$config_dir" ]]; then
    echo "❌ Cannot write to ${config_dir}."
    echo "👉 Run: sudo chown -R $(id -u):$(id -g) ${config_dir}"
    echo "   (Docker: auth.json mounts often leave ~/.config root-owned.)"
    exit 1
  fi

  mkdir -p "${config_dir}/rtk"
}

agent_cursor_installed() {
  command -v cursor &>/dev/null && return 0
  command -v agent &>/dev/null && return 0
  [[ -x /opt/cursor.AppImage ]] && return 0
  [[ -f "$HOME/.cursor/cli-config.json" ]] && return 0
  return 1
}

agent_copilot_installed() {
  command -v code &>/dev/null && return 0
  command -v copilot &>/dev/null && return 0
  [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User" ]] && return 0
  [[ -d "$HOME/Library/Application Support/Code/User" ]] && return 0
  return 1
}

agent_antigravity_installed() {
  command -v agy &>/dev/null && return 0
  [[ -d "$HOME/.gemini/antigravity-cli" ]] && return 0
  return 1
}

require_agent_installed() {
  if env_is_yes "${SKIP_AGENT_CHECK:-}"; then
    echo "⏭️ Skipping agent install check (SKIP_AGENT_CHECK=yes)."
    return 0
  fi

  case "$AGENT" in
    cursor)
      if agent_cursor_installed; then
        if command -v cursor &>/dev/null; then
          echo "✅ Cursor detected ($(command -v cursor))."
        elif command -v agent &>/dev/null; then
          echo "✅ Cursor CLI detected ($(command -v agent))."
        else
          echo "✅ Cursor detected (~/.cursor or AppImage)."
        fi
        return 0
      fi
      echo "❌ Cursor is not installed (or not detectable on this machine)."
      echo ""
      echo "Install Cursor first, then re-run this script:"
      echo "  • Cursor IDE — https://cursor.com/download"
      echo "  • Cursor CLI   — curl https://cursor.com/install -fsS | bash"
      echo "                   then: export PATH=\"\$HOME/.local/bin:\$PATH\" && agent --version"
      exit 1
      ;;
    github-copilot)
      if agent_copilot_installed; then
        if command -v code &>/dev/null; then
          echo "✅ VS Code detected ($(command -v code))."
        elif command -v copilot &>/dev/null; then
          echo "✅ GitHub Copilot CLI detected ($(command -v copilot))."
        else
          echo "✅ VS Code / Copilot config detected."
        fi
        return 0
      fi
      echo "❌ GitHub Copilot environment is not installed (or not detectable)."
      echo ""
      echo "Install GitHub Copilot first, then re-run this script:"
      echo "  • VS Code + GitHub Copilot extension — https://code.visualstudio.com/"
      echo "  • GitHub Copilot CLI — https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli"
      exit 1
      ;;
    antigravity)
      if agent_antigravity_installed; then
        echo "✅ Antigravity CLI detected ($(command -v agy 2>/dev/null || echo ~/.gemini/antigravity-cli))."
        return 0
      fi
      echo "❌ Antigravity CLI (agy) is not installed."
      echo ""
      echo "Install Antigravity CLI first, then re-run this script:"
      echo "  curl -fsSL https://antigravity.google/cli/install.sh | bash"
      echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
      echo "  agy --version"
      exit 1
      ;;
  esac
}

echo "🚀 AI Optimizer Setup (RTK + ICM/Mem0 + QMD/Graphify)"
echo "===================================================="

# -------------------------------
# AGENT SELECTION
# -------------------------------

if [[ -n "${AGENT:-}" ]]; then
  echo "Using AGENT=${AGENT} from environment."
else
  echo "Which AI agent are you using?"
  agents=("github-copilot" "cursor" "antigravity")
  select AGENT in "${agents[@]}"; do
    [[ -n "$AGENT" ]] && break
  done
fi

# Back-compat: older configs used AGENT=gemini. Treat it as Antigravity now.
if [[ "${AGENT:-}" == "gemini" ]]; then
  echo "ℹ️  Mapping AGENT=gemini -> AGENT=antigravity"
  AGENT="antigravity"
fi

case $AGENT in
  github-copilot) RTK_FLAG="--copilot" ;;
  cursor)         RTK_FLAG="--agent cursor" ;;
  antigravity)    RTK_FLAG="--agent antigravity" ;;
  *)
    echo "❌ Unknown AGENT: $AGENT"
    exit 1
    ;;
esac

require_agent_installed

# -------------------------------
# DOCS TOOL: QMD or Graphify (mutually exclusive)
# -------------------------------

select_docs_tool() {
  if [[ -z "${DOCS_TOOL:-}" && -n "${ENABLE_GRAPHIFY:-}" ]]; then
    if env_is_yes "${ENABLE_GRAPHIFY}"; then
      DOCS_TOOL="graphify"
      echo "ℹ️  Mapping ENABLE_GRAPHIFY=yes -> DOCS_TOOL=graphify"
      return 0
    fi
  fi

  if [[ -n "${DOCS_TOOL:-}" ]]; then
    case "${DOCS_TOOL}" in
      qmd|graphify|none)
        echo "Using DOCS_TOOL=${DOCS_TOOL} from environment."
        return 0
        ;;
      *)
        echo "❌ Unknown DOCS_TOOL: ${DOCS_TOOL} (use qmd, graphify, or none)"
        exit 1
        ;;
    esac
  fi

  echo ""
  echo "Choose a documentation/codebase context tool (pick one):"
  echo "  • QMD       — semantic search over docs/**/*.md (smaller projects, markdown docs only)"
  echo "  • Graphify  — knowledge graph + Cursor MCP (larger codebases, monorepos)"
  echo "  • None      — skip both"
  select DOCS_TOOL in "qmd" "graphify" "none"; do
    [[ -n "$DOCS_TOOL" ]] && break
  done
}

select_graphify_mcp() {
  if [[ -n "${GRAPHIFY_MCP:-}" ]]; then
    if env_is_yes "${GRAPHIFY_MCP}"; then
      GRAPHIFY_MCP="yes"
      echo "Using GRAPHIFY_MCP=yes from environment."
      return 0
    fi
    if env_is_no "${GRAPHIFY_MCP}"; then
      GRAPHIFY_MCP="no"
      echo "Using GRAPHIFY_MCP=no from environment."
      return 0
    fi
    echo "❌ Unknown GRAPHIFY_MCP: ${GRAPHIFY_MCP} (use yes or no)"
    exit 1
  fi

  if ! is_interactive; then
    GRAPHIFY_MCP="yes"
    echo "⏭️ Non-interactive: GRAPHIFY_MCP=yes (set GRAPHIFY_MCP=no for CLI-only)."
    return 0
  fi

  echo ""
  echo "Install Graphify with MCP extra? (needed for Cursor query_graph / get_neighbors)"
  echo "  • yes  — graphifyy[mcp]  (Cursor MCP tools)"
  echo "  • no   — graphifyy only  (CLI: graphify query / graphify path)"
  select GRAPHIFY_MCP in "yes" "no"; do
    [[ -n "$GRAPHIFY_MCP" ]] && break
  done
}

select_docs_tool
if [[ "$DOCS_TOOL" == "graphify" ]]; then
  select_graphify_mcp
fi

# -------------------------------
# GLOBAL: RTK
# -------------------------------

if ! command -v rtk &> /dev/null; then
  echo "📦 Installing RTK..."
  curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
else
  echo "✅ RTK already installed."
fi
ensure_local_bin_on_path
require_command rtk "RTK installs to ~/.local/bin. Run: export PATH=\"\$HOME/.local/bin:\$PATH\""
ensure_agent_home_dirs

echo "🔧 Configuring RTK for ${AGENT}..."
# --auto-patch: avoid interactive "Patch settings.json?" prompts (Claude side-effect on Cursor init).
# --no-patch would skip patching entirely; we want hooks installed without blocking on stdin.
if [[ "$AGENT" == "antigravity" ]]; then
  rtk init --auto-patch $RTK_FLAG
else
  rtk init -g --auto-patch $RTK_FLAG
fi

# -------------------------------
# MEMORY: ICM (local) or Mem0 (cloud) — mutually exclusive
# -------------------------------

select_memory_tool() {
  if [[ -n "${MEMORY_TOOL:-}" ]]; then
    case "${MEMORY_TOOL}" in
      icm|mem0|none)
        echo "Using MEMORY_TOOL=${MEMORY_TOOL} from environment."
        return 0
        ;;
      *)
        echo "❌ Unknown MEMORY_TOOL: ${MEMORY_TOOL} (use icm, mem0, or none)"
        exit 1
        ;;
    esac
  fi

  if [[ -n "${ENABLE_ICM:-}" ]]; then
    if env_is_yes "${ENABLE_ICM}"; then
      MEMORY_TOOL="icm"
      echo "ℹ️  Mapping ENABLE_ICM=yes -> MEMORY_TOOL=icm"
      return 0
    fi
    if env_is_no "${ENABLE_ICM}"; then
      MEMORY_TOOL="none"
      echo "ℹ️  Mapping ENABLE_ICM=no -> MEMORY_TOOL=none"
      return 0
    fi
  fi

  if [[ -n "${ENABLE_MEM0:-}" ]]; then
    if env_is_yes "${ENABLE_MEM0}"; then
      MEMORY_TOOL="mem0"
      echo "ℹ️  Mapping ENABLE_MEM0=yes -> MEMORY_TOOL=mem0"
      return 0
    fi
    if env_is_no "${ENABLE_MEM0}"; then
      MEMORY_TOOL="none"
      echo "ℹ️  Mapping ENABLE_MEM0=no -> MEMORY_TOOL=none"
      return 0
    fi
  fi

  echo ""
  echo "Choose a memory tool (pick one):"
  echo "  • ICM   — local SQLite memory, no account (https://github.com/rtk-ai/icm)"
  echo "  • Mem0  — cloud memory, requires API key (https://github.com/mem0ai/mem0)"
  echo "  • None  — skip memory"
  select MEMORY_TOOL in "icm" "mem0" "none"; do
    [[ -n "$MEMORY_TOOL" ]] && break
  done
}

select_memory_tool

# -------------------------------
# ICM (https://github.com/rtk-ai/icm)
# -------------------------------

ensure_gemini_settings_path() {
  local gemini_dir="$HOME/.gemini"
  mkdir -p "$gemini_dir"
  if [ ! -w "$gemini_dir" ]; then
    echo "⚠️ $gemini_dir is not writable by $(whoami)."
    if ask_permission "Fix ownership/permissions for ${gemini_dir}? (requires sudo)" "ALLOW_SUDO"; then
      echo "🔧 Attempting to fix ownership/permissions for $gemini_dir..."
      sudo_cmd chown -R "$(id -u):$(id -g)" "$gemini_dir"
      chmod u+rwx "$gemini_dir"
    fi
  fi
  if [ ! -w "$gemini_dir" ]; then
    echo "❌ Cannot write to $gemini_dir."
    echo "👉 Run: sudo chown -R $(id -u):$(id -g) $gemini_dir"
    exit 1
  fi
}

install_icm_if_missing() {
  if command -v icm &> /dev/null; then
    echo "✅ ICM already installed ($(icm --version 2>/dev/null || true))."
    return 0
  fi
  echo "📦 Installing ICM..."
  curl -fsSL https://raw.githubusercontent.com/rtk-ai/icm/main/install.sh | sh
  ensure_local_bin_on_path
}

resolve_icm_binary() {
  local icm_bin
  icm_bin="$(command -v icm 2>/dev/null || true)"
  if [[ -n "$icm_bin" ]]; then
    # Prefer absolute path so Cursor MCP works regardless of PATH in the IDE.
    if command -v realpath &>/dev/null; then
      realpath "$icm_bin"
    elif command -v readlink &>/dev/null; then
      readlink -f "$icm_bin" 2>/dev/null || echo "$icm_bin"
    else
      echo "$icm_bin"
    fi
    return 0
  fi
  if [[ -x "$HOME/.local/bin/icm" ]]; then
    echo "$HOME/.local/bin/icm"
    return 0
  fi
  echo "icm"
}

merge_icm_into_cursor_mcp() {
  local mcp_file="$HOME/.cursor/mcp.json"
  local icm_bin="${1:-}"
  mkdir -p "$HOME/.cursor"

  if [[ -z "$icm_bin" ]]; then
    icm_bin="$(resolve_icm_binary)"
  fi

  if ! command -v python3 &>/dev/null; then
    if [[ -f "$mcp_file" ]]; then
      echo "⚠️ python3 not found; cannot safely merge ICM into existing ~/.cursor/mcp.json."
      echo "   Add manually: \"icm\": { \"command\": \"${icm_bin}\", \"args\": [\"serve\"], \"env\": {} }"
      return 1
    fi
    echo "⚠️ python3 not found; writing minimal ~/.cursor/mcp.json for ICM."
    cat > "$mcp_file" << EOF
{
  "mcpServers": {
    "icm": {
      "command": "${icm_bin}",
      "args": ["serve"],
      "env": {}
    }
  }
}
EOF
    return 0
  fi

  ICM_MCP_FILE="$mcp_file" ICM_BIN="$icm_bin" python3 << 'PY'
import json
import os

mcp_file = os.environ["ICM_MCP_FILE"]
entry = {
    "command": os.environ["ICM_BIN"],
    "args": ["serve"],
    "env": {},
}

data = {}
if os.path.exists(mcp_file):
    with open(mcp_file, encoding="utf-8") as f:
        data = json.load(f)

if "mcpServers" not in data or not isinstance(data["mcpServers"], dict):
    data["mcpServers"] = {}

data["mcpServers"]["icm"] = entry

with open(mcp_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

write_cursor_icm_rule() {
  [[ "$AGENT" == "cursor" ]] || return 0
  local rules_dir="$HOME/.cursor/rules"
  local rule_file="$rules_dir/icm.mdc"
  mkdir -p "$rules_dir"

  # Prefer ICM's own skill install; only write a fallback if missing.
  if [[ -f "$rule_file" ]]; then
    echo "✅ ICM Cursor rule already present: $rule_file"
    return 0
  fi

  echo "📝 Writing Cursor rule: $rule_file (ICM MCP fallback)"
  cat > "$rule_file" << 'EOF'
---
description: ICM persistent local memory for AI agents
alwaysApply: true
---

Use ICM MCP tools proactively to maintain long-term memory across sessions.

RECALL (icm_memory_recall): At the start of a task, search for relevant past context — decisions, resolved errors, user preferences.

STORE (icm_memory_store): Store when ANY of these triggers occur:
1. Error resolved → topic: errors-resolved, importance: high
2. Architecture/design decision made → topic: decisions-{project}, importance: high
3. User preference discovered → topic: preferences, importance: critical
4. Significant task completed → topic: context-{project}, importance: high

CLI fallback: `icm recall` / `icm store`. Same SQLite DB as MCP.

Do NOT store: trivial details, ephemeral state, information already in project docs.
Restart Cursor after MCP config changes. Verify: icm_memory_recall for "project setup".
EOF
  echo "✅ ICM Cursor rule installed."
}

setup_icm_for_agent() {
  local icm_bin
  local icm_init_force=()

  install_icm_if_missing
  require_command icm "ICM installs to ~/.local/bin. Run: export PATH=\"\$HOME/.local/bin:\$PATH\""
  ensure_config_dir_writable

  if icm init --help 2>&1 | grep -q -- '--force'; then
    icm_init_force=(--force)
  fi

  icm_bin="$(resolve_icm_binary)"

  case "$AGENT" in
    cursor)
      echo "🔧 ICM for Cursor: MCP (~/.cursor/mcp.json) + rule (~/.cursor/rules/icm.mdc)..."
      # Official auto-config (may no-op if Cursor not detected in some environments).
      icm init --mode mcp "${icm_init_force[@]}" || echo "⚠️ icm init --mode mcp returned non-zero; applying explicit MCP merge."
      icm init --mode skill "${icm_init_force[@]}" || echo "⚠️ icm init --mode skill returned non-zero; writing fallback rule."

      # Explicit merge so ICM MCP coexists with Mem0/Graphify/other servers.
      echo "🔧 Registering ICM MCP in ~/.cursor/mcp.json"
      echo "   command: ${icm_bin} serve"
      merge_icm_into_cursor_mcp "$icm_bin"
      write_cursor_icm_rule

      if [[ -f "$HOME/.cursor/mcp.json" ]] && grep -q '"icm"' "$HOME/.cursor/mcp.json" 2>/dev/null; then
        echo "✅ ICM MCP configured in ~/.cursor/mcp.json"
      else
        echo "⚠️ ~/.cursor/mcp.json exists but may not list icm — check manually."
      fi
      if [[ ! -f "$HOME/.cursor/rules/icm.mdc" ]]; then
        echo "⚠️ Expected ~/.cursor/rules/icm.mdc"
      else
        echo "✅ ICM Cursor rule: ~/.cursor/rules/icm.mdc"
      fi
      echo ""
      echo "ℹ️  Cursor does not use icm hook (post/compact/prompt). Memory via MCP or: icm recall / icm store"
      echo "   Restart Cursor / Cursor CLI after MCP config changes."
      ;;
    antigravity)
      ensure_gemini_settings_path
      echo "🔧 ICM for Antigravity CLI: MCP + CLI instructions..."
      icm init --mode mcp "${icm_init_force[@]}"
      icm init --mode cli "${icm_init_force[@]}"
      ;;
    github-copilot)
      echo "🔧 ICM for GitHub Copilot: MCP + CLI instructions..."
      icm init --mode mcp "${icm_init_force[@]}"
      icm init --mode cli "${icm_init_force[@]}"
      ;;
  esac

  if [[ "$AGENT" == "cursor" ]]; then
    echo ""
    echo "Also install ICM hooks for Claude Code / Gemini / Codex? (optional; not used by Cursor)"
    if [[ -n "${ENABLE_ICM_HOOKS:-}" ]]; then
      echo "Using ENABLE_ICM_HOOKS=${ENABLE_ICM_HOOKS} from environment."
    elif ! is_interactive; then
      ENABLE_ICM_HOOKS="no"
      echo "⏭️ Non-interactive: skipping ICM hooks (set ENABLE_ICM_HOOKS=yes to enable)."
    else
      select HOOKS_CHOICE in "No" "Yes"; do
        case "$HOOKS_CHOICE" in
          Yes) ENABLE_ICM_HOOKS="yes"; break ;;
          No)  ENABLE_ICM_HOOKS="no"; break ;;
        esac
      done
    fi
    if env_is_yes "${ENABLE_ICM_HOOKS:-no}"; then
      ensure_gemini_settings_path
      echo "🔧 ICM hook mode (Claude Code, Gemini, Codex, Copilot CLI, OpenCode)..."
      icm init --mode hook "${icm_init_force[@]}"
    fi
  else
    ensure_gemini_settings_path
    echo "🔧 ICM hook mode (Claude Code, Gemini, Codex, Copilot CLI, OpenCode)..."
    icm init --mode hook "${icm_init_force[@]}"
  fi
}

# -------------------------------
# Mem0 (https://github.com/mem0ai/mem0)
# -------------------------------

ensure_mem0_api_key() {
  if [[ -n "${MEM0_API_KEY:-}" ]]; then
    echo "✅ MEM0_API_KEY is set."
    return 0
  fi

  echo ""
  echo "Mem0 requires an API key from https://app.mem0.ai"
  if ! is_interactive; then
    echo "❌ Set MEM0_API_KEY and re-run."
    exit 1
  fi

  read -rsp "Enter MEM0_API_KEY (starts with m0-): " MEM0_API_KEY
  echo ""
  if [[ -z "$MEM0_API_KEY" ]]; then
    echo "❌ API key required for Mem0."
    exit 1
  fi
  export MEM0_API_KEY

  echo ""
  echo "Persist MEM0_API_KEY in your shell profile?"
  select PERSIST_CHOICE in "No" "Yes"; do
    case "$PERSIST_CHOICE" in
      Yes)
        local rc_file="$HOME/.bashrc"
        if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL:-}" == *zsh* ]]; then
          rc_file="$HOME/.zshrc"
        fi
        if ! grep -q 'MEM0_API_KEY=' "$rc_file" 2>/dev/null; then
          echo "export MEM0_API_KEY=\"${MEM0_API_KEY}\"" >> "$rc_file"
          echo "✅ Added MEM0_API_KEY to ${rc_file}"
        else
          echo "ℹ️  MEM0_API_KEY already present in ${rc_file}"
        fi
        break
        ;;
      No) break ;;
    esac
  done
}

merge_mem0_into_cursor_mcp() {
  local mcp_file="$HOME/.cursor/mcp.json"
  mkdir -p "$HOME/.cursor"

  if ! command -v python3 &>/dev/null; then
    if [[ -f "$mcp_file" ]]; then
      echo "⚠️ python3 not found; cannot safely merge Mem0 into existing ~/.cursor/mcp.json."
      echo "   Add Mem0 manually — see https://docs.mem0.ai/integrations/cursor"
      return 1
    fi
    echo "⚠️ python3 not found; writing minimal ~/.cursor/mcp.json for Mem0."
    cat > "$mcp_file" << 'EOF'
{
  "mcpServers": {
    "mem0": {
      "url": "https://mcp.mem0.ai/mcp/",
      "headers": {
        "Authorization": "Token ${env:MEM0_API_KEY}"
      }
    }
  }
}
EOF
    return 0
  fi

  MEM0_MCP_FILE="$mcp_file" python3 << 'PY'
import json
import os

mcp_file = os.environ["MEM0_MCP_FILE"]
mem0_entry = {
    "url": "https://mcp.mem0.ai/mcp/",
    "headers": {
        "Authorization": "Token ${env:MEM0_API_KEY}"
    },
}

data = {}
if os.path.exists(mcp_file):
    with open(mcp_file, encoding="utf-8") as f:
        data = json.load(f)

if "mcpServers" not in data or not isinstance(data["mcpServers"], dict):
    data["mcpServers"] = {}

data["mcpServers"]["mem0"] = mem0_entry

with open(mcp_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

write_cursor_mem0_rule() {
  [[ "$AGENT" == "cursor" ]] || return 0
  local rules_dir="$HOME/.cursor/rules"
  local rule_file="$rules_dir/mem0.mdc"
  mkdir -p "$rules_dir"
  echo "📝 Writing Cursor rule: $rule_file (Mem0)"
  cat > "$rule_file" << 'EOF'
---
description: Mem0 persistent memory for AI agents
alwaysApply: true
---

Use Mem0 MCP tools proactively to maintain long-term memory across sessions.

RECALL (search_memories): At the start of a task, search for relevant past context — decisions, resolved errors, user preferences.

STORE (add_memory): Store when ANY of these triggers occur:
1. Error resolved → importance: high
2. Architecture/design decision made → importance: high
3. User preference discovered → importance: critical
4. Significant task completed → importance: high

Do NOT store: trivial details, ephemeral state, information already in project docs.

Restart Cursor after MCP config changes. Verify: search_memories for "project setup".
EOF
  echo "✅ Mem0 Cursor rule installed."
}

mem0_mcp_client_name() {
  case "$AGENT" in
    cursor)         echo "cursor" ;;
    github-copilot) echo "vscode" ;;
    antigravity)    echo "opencode" ;;
    *)              echo "cursor" ;;
  esac
}

setup_mem0_for_agent() {
  ensure_mem0_api_key

  case "$AGENT" in
    cursor)
      echo "🔧 Mem0 for Cursor: MCP (~/.cursor/mcp.json) + rule (~/.cursor/rules/mem0.mdc)..."
      merge_mem0_into_cursor_mcp
      write_cursor_mem0_rule
      if [[ -f "$HOME/.cursor/mcp.json" ]] && ! grep -q '"mem0"' "$HOME/.cursor/mcp.json" 2>/dev/null; then
        echo "⚠️ ~/.cursor/mcp.json exists but may not list mem0 — check manually."
      else
        echo "✅ Mem0 MCP configured in ~/.cursor/mcp.json"
      fi
      echo ""
      echo "ℹ️  Restart Cursor / Cursor CLI after MCP config changes."
      echo "   Verify: search_memories for \"project setup\""
      ;;
    *)
      local client
      client="$(mem0_mcp_client_name)"
      echo "🔧 Mem0 MCP for ${AGENT} (client: ${client})..."
      if command -v npx &>/dev/null; then
        npx -y mcp-add \
          --name mem0-mcp \
          --type http \
          --url "https://mcp.mem0.ai/mcp/" \
          --clients "$client" || echo "⚠️ mcp-add failed; configure Mem0 MCP manually."
      else
        echo "⚠️ npx not found. Add Mem0 MCP manually: https://docs.mem0.ai/integrations/cursor"
      fi
      ;;
  esac
}

case "$MEMORY_TOOL" in
  icm)
    setup_icm_for_agent
    ;;
  mem0)
    setup_mem0_for_agent
    ;;
  none)
    echo "⏭️ Skipping memory tool initialization."
    ;;
esac

# -------------------------------
# Cursor: optimizer rule (RTK + memory + QMD or Graphify)
# -------------------------------

write_cursor_compression_rule() {
  [[ "$AGENT" == "cursor" ]] || return 0
  local rules_dir="$HOME/.cursor/rules"
  local rule_file="$rules_dir/compression.mdc"
  mkdir -p "$rules_dir"

  local docs_line=""
  case "$DOCS_TOOL" in
    qmd)
      docs_line="- Project documentation: prefer \`qmd search\` / \`qmd query -c ${QMD_COLLECTION}\` (collection \`qmd://${QMD_COLLECTION}\`) before reading many \`.md\` files."
      ;;
    graphify)
      docs_line="- Codebase relationships: prefer Graphify MCP (\`query_graph\`, \`get_neighbors\`, \`shortest_path\`) or CLI (\`graphify query\` / \`graphify path\`). Build once: \`graphify .\` → \`graphify-out/graph.json\`."
      ;;
  esac

  local memory_line=""
  case "$MEMORY_TOOL" in
    icm)
      memory_line="- Cross-session memory: use ICM MCP tools (\`icm_memory_recall\`, \`icm_memory_store\`) or CLI (\`icm recall\`, \`icm store\`). Local SQLite — https://github.com/rtk-ai/icm"
      ;;
    mem0)
      memory_line="- Cross-session memory: use Mem0 MCP tools (\`search_memories\`, \`add_memory\`, \`get_memories\`). Cloud — https://github.com/mem0ai/mem0"
      ;;
  esac

  echo "📝 Writing Cursor rule: $rule_file (RTK + ${MEMORY_TOOL} + ${DOCS_TOOL})..."
  cat > "$rule_file" << EOF
---
description: Token optimization defaults (RTK, ${MEMORY_TOOL}, ${DOCS_TOOL})
alwaysApply: true
---

## Optimization defaults

- Large shell file reads: prefer \`rtk read\` over \`cat\` / \`head\` when using Shell.
${docs_line}
${memory_line}
- Do not stack redundant compression (RTK already compresses Shell output via hooks).
EOF
  echo "✅ Cursor optimizer rule installed."
}

# -------------------------------
# QMD (when DOCS_TOOL=qmd)
# -------------------------------

node_npm_ready() {
  local node_major="0"
  if command -v node &> /dev/null; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  command -v npm &> /dev/null && command -v node &> /dev/null && [ "$node_major" -ge 22 ]
}

ensure_node_npm() {
  local node_major="0"
  if command -v node &> /dev/null; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if node_npm_ready; then
    return 0
  fi

  if command -v node &> /dev/null || command -v npm &> /dev/null; then
    echo "⚠️ Node.js/npm found but version ${node_major:-unknown} is below 22 (QMD requires 22+)."
  else
    echo "⚠️ Node.js/npm not found (QMD requires Node.js 22+)."
  fi

  if ! ask_permission "Install or upgrade Node.js 22+ via system package manager? (requires sudo)" "INSTALL_NODEJS"; then
    echo "❌ Node.js/npm 22+ is required for QMD."
    echo "   Install manually, or re-run with INSTALL_NODEJS=yes (or AUTO_INSTALL_PREREQS=yes)."
    exit 1
  fi

  echo "📦 Installing/upgrading Node.js/npm prerequisites..."
  if command -v apt-get &> /dev/null; then
    sudo_cmd apt-get update
    sudo_cmd apt-get install -y ca-certificates curl gnupg
    sudo_cmd mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo_cmd gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | sudo_cmd tee /etc/apt/sources.list.d/nodesource.list > /dev/null
    sudo_cmd apt-get update
    sudo_cmd apt-get install -y nodejs
  elif command -v dnf &> /dev/null; then
    sudo_cmd dnf install -y nodejs npm
  elif command -v yum &> /dev/null; then
    sudo_cmd yum install -y nodejs npm
  elif command -v pacman &> /dev/null; then
    sudo_cmd pacman -Sy --noconfirm nodejs npm
  elif command -v zypper &> /dev/null; then
    sudo_cmd zypper --non-interactive install nodejs npm
  else
    echo "❌ Unsupported package manager. Install Node.js 22+ manually, then re-run."
    exit 1
  fi
  node_major="0"
  if command -v node &> /dev/null; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if ! command -v npm &> /dev/null || ! command -v node &> /dev/null || [ "$node_major" -lt 22 ]; then
    echo "❌ Node.js/npm 22+ installation did not complete successfully."
    exit 1
  fi
}

ensure_user_writable_npm_prefix() {
  local npm_prefix
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ -w "$npm_prefix" ]; then
    return 0
  fi

  local user_prefix="$HOME/.npm-global"
  echo "🔧 Configuring user-writable npm prefix: ${user_prefix}"
  mkdir -p "$user_prefix"
  npm config set prefix "$user_prefix"
  ensure_npm_prefix_bin_on_path
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  [ -n "$npm_prefix" ] && [ -w "$npm_prefix" ]
}

install_global_npm_package() {
  local package_name="$1"
  local npm_prefix

  ensure_user_writable_npm_prefix || true
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ -w "$npm_prefix" ]; then
    npm install -g "$package_name"
    ensure_npm_prefix_bin_on_path
    return 0
  fi

  if ask_permission "Install npm package '${package_name}' globally with sudo? (prefix: ${npm_prefix:-unknown})" "ALLOW_SUDO"; then
    sudo_cmd npm install -g "$package_name"
    ensure_npm_prefix_bin_on_path
    return 0
  fi

  echo "❌ Cannot install '${package_name}' globally: npm prefix '${npm_prefix}' is not writable."
  echo "   Fix prefix manually (npm config set prefix \"\$HOME/.npm-global\") or re-run with ALLOW_SUDO=yes."
  exit 1
}

ensure_npm_prefix_bin_on_path() {
  local npm_prefix
  local npm_bin_dir
  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  npm_bin_dir="${npm_prefix}/bin"

  if [ -d "$npm_bin_dir" ] && [[ ":$PATH:" != *":$npm_bin_dir:"* ]]; then
    export PATH="${npm_bin_dir}:$PATH"
  fi
}

qmd_docs_have_markdown() {
  [[ -d docs ]] && find docs -type f -name '*.md' -print -quit | grep -q .
}

PROJECT_SLUG="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
PROJECT_SLUG="${PROJECT_SLUG%-}"
QMD_COLLECTION="${PROJECT_SLUG:-project}-docs"

setup_qmd() {
  export NODE_NO_WARNINGS=1
  ensure_node_npm
  ensure_npm_prefix_bin_on_path

  if ! command -v qmd &> /dev/null; then
    echo "📦 Installing QMD globally..."
    install_global_npm_package @tobilu/qmd
  else
    echo "✅ QMD already installed."
  fi

  if [[ "$AGENT" == "antigravity" ]]; then
    ensure_local_bin_on_path
    require_command agy "Install Antigravity CLI first: curl -fsSL https://antigravity.google/cli/install.sh | bash"
  fi

  if [[ ! -d docs ]]; then
    echo "📂 No docs/ directory found. Create one?"
    select yn in "Yes" "No"; do
      case $yn in
        Yes) mkdir -p docs; echo "➡️ Created docs/ directory."; break ;;
        No)  echo "⏭️ Skipping docs creation."; break ;;
      esac
    done
  fi

  if [[ -d docs ]]; then
    if ! qmd collection list 2>/dev/null | grep -Eq "(^|[[:space:]])${QMD_COLLECTION}([[:space:]]|$)"; then
      echo "📚 Adding docs/ as QMD collection '${QMD_COLLECTION}'..."
      qmd collection add ./docs --name "$QMD_COLLECTION" --mask "**/*.md"
      echo "📝 Adding context for collection '${QMD_COLLECTION}'..."
      qmd context add "qmd://${QMD_COLLECTION}" "Project documentation and notes"
    else
      echo "✅ QMD collection '${QMD_COLLECTION}' already exists."
    fi

    if qmd_docs_have_markdown; then
      echo "🔄 Updating '${QMD_COLLECTION}' for semantic search..."
      qmd_path_prefix=""
      if [[ -x /usr/bin/node ]] && /usr/bin/node -p 'process.versions.node.split(".")[0]' 2>/dev/null | grep -qE '^2[2-9]|[3-9][0-9]'; then
        qmd_path_prefix="PATH=/usr/bin:"
      fi
      PATH="${qmd_path_prefix}${PATH}" qmd update
      PATH="${qmd_path_prefix}${PATH}" qmd embed
    else
      echo "⚠️ No markdown under docs/ yet. Skipping embed."
      echo "   When docs exist, run: qmd update && qmd embed"
    fi
  fi

  local hook_file=".git/hooks/post-commit"
  if [[ -d .git ]]; then
    echo "🔧 Setting up Git hook for QMD re-embedding..."
    mkdir -p .git/hooks
    cat << EOF > "$hook_file"
#!/bin/sh
# Auto re-embed docs with QMD after each commit (${QMD_COLLECTION})
if command -v qmd >/dev/null 2>&1; then
  if [ -d "docs" ] && find docs -type f -name '*.md' -print -quit | grep -q .; then
    if [ -x /usr/bin/node ]; then
      export PATH="/usr/bin:\$PATH"
    fi
    echo "🔄 Updating QMD collection '${QMD_COLLECTION}' and embeddings..."
    qmd update
    qmd embed
  fi
fi
EOF
    chmod +x "$hook_file"
    echo "✅ Git hook installed: .git/hooks/post-commit"
  else
    echo "⚠️ No .git directory found. Skipping Git hook setup."
  fi
}

# -------------------------------
# Graphify (when DOCS_TOOL=graphify)
# -------------------------------

ensure_python_for_graphify() {
  command -v python3 >/dev/null 2>&1
}

apt_install_packages() {
  local packages=("$@")
  if ! command -v apt-get &> /dev/null; then
    return 1
  fi
  if ! ask_permission "Install apt packages via sudo: ${packages[*]}?" "INSTALL_APT_PACKAGES"; then
    echo "⏭️ Skipping apt install: ${packages[*]}"
    return 1
  fi
  sudo_cmd apt-get update
  sudo_cmd apt-get install -y "${packages[@]}"
}

ensure_pipx() {
  if command -v pipx &> /dev/null; then
    return 0
  fi
  echo "📦 pipx not found; installing (recommended for Graphify on PEP 668 / Debian Python)..."
  apt_install_packages pipx || return 1
  command -v pipx &> /dev/null
}

write_cursor_graphify_rule() {
  [[ "$AGENT" == "cursor" ]] || return 0
  local rules_dir="$HOME/.cursor/rules"
  local rule_file="$rules_dir/graphify.mdc"
  mkdir -p "$rules_dir"
  echo "📝 Writing Cursor rule: $rule_file (Graphify + MCP)"
  cat > "$rule_file" << 'EOF'
---
description: Graphify knowledge graph + MCP tools
alwaysApply: true
---

## Graphify (knowledge graph)

- Build once per codebase: `graphify .` → `graphify-out/graph.json` (required before MCP works).
- Prefer MCP tools when available: `query_graph`, `get_node`, `get_neighbors`, `shortest_path`.
- CLI fallback:
  - `graphify query "<question>"`
  - `graphify path "<From>" "<To>"`
  - `graphify explain "<Node>"`

When asked how modules/files/definitions relate, prefer Graphify (MCP or CLI) over ad-hoc grepping.
EOF
}

# True when INTERPRETER can run `python -m graphify.serve` (requires graphifyy[mcp]).
graphify_python_can_serve() {
  local interpreter="$1"
  [[ -n "$interpreter" && -x "$interpreter" ]] \
    && "$interpreter" -c "import graphify.serve" >/dev/null 2>&1
}

# Resolve a Python for Graphify MCP (`python -m graphify.serve`). Prefer pipx/uv
# venvs with the [mcp] extra over system python that only has the base package.
resolve_graphify_python() {
  local candidate graphify_bin shebang

  for candidate in \
    "$HOME/.local/share/pipx/venvs/graphifyy/bin/python" \
    "$HOME/.local/share/uv/tools/graphifyy/bin/python"
  do
    if graphify_python_can_serve "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  graphify_bin="$(command -v graphify 2>/dev/null || true)"
  if [[ -n "$graphify_bin" ]]; then
    candidate="$(dirname "$graphify_bin")/python"
    if graphify_python_can_serve "$candidate"; then
      echo "$candidate"
      return 0
    fi
    shebang="$(head -1 "$graphify_bin" 2>/dev/null | sed 's/^#![[:space:]]*//' || true)"
    # shebang may be "/usr/bin/env python3" — only accept a real interpreter path
    if [[ -n "$shebang" && "$shebang" != *" "* && -x "$shebang" ]] \
      && graphify_python_can_serve "$shebang"; then
      echo "$shebang"
      return 0
    fi
  fi

  candidate="$(command -v python3 2>/dev/null || true)"
  if graphify_python_can_serve "$candidate"; then
    echo "$candidate"
    return 0
  fi

  # Fallback: CLI-only graphify (MCP will fail until graphifyy[mcp] is installed).
  for candidate in \
    "$HOME/.local/share/pipx/venvs/graphifyy/bin/python" \
    "$HOME/.local/share/uv/tools/graphifyy/bin/python" \
    "$(command -v python3 2>/dev/null || true)"
  do
    if [[ -n "$candidate" && -x "$candidate" ]] && "$candidate" -c "import graphify" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  command -v python3
}

ensure_graphify_mcp_extra() {
  # Prefer reinstall/inject with [mcp] so `python -m graphify.serve` works.
  if python3 -c "import graphify.serve" >/dev/null 2>&1; then
    return 0
  fi
  local gpy
  gpy="$(resolve_graphify_python)"
  if [[ -n "$gpy" ]] && "$gpy" -c "import graphify.serve" >/dev/null 2>&1; then
    return 0
  fi

  echo "📦 Ensuring Graphify MCP extra (graphifyy[mcp])..."
  if command -v pipx &> /dev/null && pipx list 2>/dev/null | grep -qi graphifyy; then
    pipx inject graphifyy 'graphifyy[mcp]' 2>/dev/null \
      || pipx install --force 'graphifyy[mcp]' \
      || true
  elif command -v uv &> /dev/null; then
    uv tool install --force 'graphifyy[mcp]' || true
  elif python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip install --user --upgrade 'graphifyy[mcp]' 2>/dev/null || true
  fi
}

merge_graphify_into_cursor_mcp() {
  local mcp_file="$HOME/.cursor/mcp.json"
  local graph_json="${1:-}"
  local python_cmd="${2:-python3}"
  mkdir -p "$HOME/.cursor"

  if [[ -z "$graph_json" ]]; then
    graph_json="$(pwd)/graphify-out/graph.json"
  fi

  if ! command -v python3 &>/dev/null; then
    if [[ -f "$mcp_file" ]]; then
      echo "⚠️ python3 not found; cannot safely merge Graphify into existing ~/.cursor/mcp.json."
      echo "   Add manually:"
      echo "   \"graphify\": { \"command\": \"${python_cmd}\", \"args\": [\"-m\", \"graphify.serve\", \"${graph_json}\"] }"
      return 1
    fi
    echo "⚠️ python3 not found; writing minimal ~/.cursor/mcp.json for Graphify."
    cat > "$mcp_file" << EOF
{
  "mcpServers": {
    "graphify": {
      "command": "${python_cmd}",
      "args": ["-m", "graphify.serve", "${graph_json}"]
    }
  }
}
EOF
    return 0
  fi

  GRAPHIFY_MCP_FILE="$mcp_file" \
  GRAPHIFY_PYTHON="$python_cmd" \
  GRAPHIFY_GRAPH_JSON="$graph_json" \
  python3 << 'PY'
import json
import os

mcp_file = os.environ["GRAPHIFY_MCP_FILE"]
entry = {
    "command": os.environ["GRAPHIFY_PYTHON"],
    "args": ["-m", "graphify.serve", os.environ["GRAPHIFY_GRAPH_JSON"]],
}

data = {}
if os.path.exists(mcp_file):
    with open(mcp_file, encoding="utf-8") as f:
        data = json.load(f)

if "mcpServers" not in data or not isinstance(data["mcpServers"], dict):
    data["mcpServers"] = {}

data["mcpServers"]["graphify"] = entry

with open(mcp_file, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

install_graphify_cli() {
  ensure_local_bin_on_path

  local with_mcp=0
  if env_is_yes "${GRAPHIFY_MCP:-yes}"; then
    with_mcp=1
  fi

  if command -v graphify &> /dev/null; then
    echo "✅ Graphify already present: $(command -v graphify)"
    if [[ "$with_mcp" -eq 1 ]]; then
      ensure_graphify_mcp_extra
    fi
    return 0
  fi

  if [[ "$with_mcp" -eq 1 ]]; then
    if ensure_pipx; then
      echo "📦 Installing Graphify via pipx (graphifyy[mcp])..."
      if pipx install 'graphifyy[mcp]'; then
        return 0
      fi
      echo "⚠️ pipx install with [mcp] failed; trying plain graphifyy + inject..."
      if pipx install graphifyy; then
        pipx inject graphifyy 'graphifyy[mcp]' 2>/dev/null || true
        return 0
      fi
      pipx upgrade graphifyy 2>/dev/null && pipx inject graphifyy 'graphifyy[mcp]' 2>/dev/null && return 0
    fi

    if command -v uv &> /dev/null; then
      echo "📦 Installing Graphify via uv tool (graphifyy[mcp])..."
      uv tool install 'graphifyy[mcp]' && return 0
      uv tool install graphifyy && return 0
    fi

    if python3 -m pip --version >/dev/null 2>&1; then
      echo "📦 Installing Graphify via pip --user (graphifyy[mcp])..."
      if python3 -m pip install --user --upgrade 'graphifyy[mcp]' 2>/dev/null; then
        return 0
      fi
      if python3 -m pip install --user --upgrade graphifyy 2>/dev/null; then
        return 0
      fi
    fi

    echo "⚠️ Failed to install graphifyy."
    echo "   On Debian/Ubuntu/WSL, install pipx and retry: sudo apt install pipx && pipx install 'graphifyy[mcp]'"
    return 1
  fi

  if ensure_pipx; then
    echo "📦 Installing Graphify via pipx (graphifyy, CLI only)..."
    pipx install graphifyy && return 0
  fi

  if command -v uv &> /dev/null; then
    echo "📦 Installing Graphify via uv tool (graphifyy, CLI only)..."
    uv tool install graphifyy && return 0
  fi

  if python3 -m pip --version >/dev/null 2>&1; then
    echo "📦 Installing Graphify via pip --user (graphifyy, CLI only)..."
    python3 -m pip install --user --upgrade graphifyy && return 0
  fi

  echo "⚠️ Failed to install graphifyy."
  echo "   On Debian/Ubuntu/WSL, install pipx and retry: sudo apt install pipx && pipx install graphifyy"
  return 1
}

setup_graphify() {
  local graph_json gpy

  if ! ensure_python_for_graphify; then
    echo "⚠️ Python3 not found; skipping Graphify installation."
    return 0
  fi

  if ! install_graphify_cli; then
    echo "⚠️ Skipping Graphify."
    return 0
  fi

  ensure_local_bin_on_path
  if ! command -v graphify &> /dev/null; then
    echo "⚠️ graphify not on PATH after install. Add ~/.local/bin to PATH and re-run."
    return 0
  fi

  echo "🔧 Running: graphify install"
  graphify install || echo "⚠️ graphify install failed; you can re-run manually later."

  if [[ -d .git ]]; then
    echo "🔧 Setting up Git hook for Graphify graph rebuild..."
    if graphify hook install; then
      echo "✅ Git hook installed: .git/hooks/post-commit (graphify)"
    else
      echo "⚠️ graphify hook install failed; run manually: graphify hook install"
    fi
  else
    echo "⚠️ No .git directory found. Skipping Graphify git hook setup."
  fi

  graph_json="$(pwd)/graphify-out/graph.json"
  if [[ ! -f "$graph_json" ]]; then
    echo ""
    echo "No graphify-out/graph.json yet. Build knowledge graph now? (can take a while on large repos)"
    if [[ -n "${BUILD_GRAPHIFY:-}" ]]; then
      echo "Using BUILD_GRAPHIFY=${BUILD_GRAPHIFY} from environment."
    elif ! is_interactive; then
      BUILD_GRAPHIFY="no"
      echo "⏭️ Non-interactive: skipping graph build (set BUILD_GRAPHIFY=yes to enable)."
    else
      select BUILD_GRAPHIFY in "No" "Yes"; do
        case "$BUILD_GRAPHIFY" in
          Yes|No) break ;;
        esac
      done
    fi
    if env_is_yes "${BUILD_GRAPHIFY:-}"; then
      echo "🔧 Running: graphify ."
      graphify . || echo "⚠️ graphify . failed; run manually later, then restart Cursor."
    else
      if env_is_no "${GRAPHIFY_MCP:-}"; then
        echo "⏭️ Skipping graph build. Later: graphify ."
      else
        echo "⏭️ Skipping graph build. Later: graphify . && restart Cursor (MCP needs graph.json)."
      fi
    fi
  else
    echo "✅ Found existing graph: ${graph_json}"
  fi

  if [[ "$AGENT" == "cursor" ]]; then
    echo "🔧 Configuring Cursor integration: graphify cursor install"
    graphify cursor install || echo "⚠️ graphify cursor install failed; check Cursor rule manually."
    write_cursor_graphify_rule

    if env_is_no "${GRAPHIFY_MCP:-}"; then
      echo "⏭️ Skipping Graphify MCP registration (GRAPHIFY_MCP=no). Use CLI: graphify query / graphify path"
    else
      ensure_graphify_mcp_extra
      gpy="$(resolve_graphify_python)"
      echo "🔧 Registering Graphify MCP in ~/.cursor/mcp.json"
      echo "   python: ${gpy}"
      echo "   graph:  ${graph_json}"
      if ! graphify_python_can_serve "$gpy"; then
        echo "⚠️ ${gpy} cannot run graphify.serve — install graphifyy[mcp] on this interpreter or use pipx."
      fi
      merge_graphify_into_cursor_mcp "$graph_json" "$gpy"
      if [[ -f "$HOME/.cursor/mcp.json" ]] && grep -q '"graphify"' "$HOME/.cursor/mcp.json" 2>/dev/null; then
        echo "✅ Graphify MCP configured in ~/.cursor/mcp.json"
      else
        echo "⚠️ Graphify MCP may not be listed in ~/.cursor/mcp.json — check manually."
      fi
      if [[ ! -f "$graph_json" ]]; then
        echo "⚠️ MCP is registered but ${graph_json} is missing until you run: graphify ."
      fi
    fi
  fi
}

case "$DOCS_TOOL" in
  qmd)
    echo ""
    echo "📁 Setting up QMD..."
    setup_qmd
    ;;
  graphify)
    echo ""
    echo "📁 Setting up Graphify..."
    setup_graphify
    ;;
  none)
    echo ""
    echo "⏭️ Skipping QMD and Graphify."
    ;;
esac

write_cursor_compression_rule

# -------------------------------
# GEMINI.md / AGENTS.md
# -------------------------------

write_agents_compression_section() {
  local target="$1"
  local docs_snippet=""
  local memory_snippet=""

  case "$MEMORY_TOOL" in
    icm)
      memory_snippet=$'- **ICM**  \n  Local cross-session memory (SQLite). **Cursor:** MCP (`~/.cursor/mcp.json`) + rule (`~/.cursor/rules/icm.mdc`) — use `icm_memory_recall` / `icm_memory_store` or `icm recall` / `icm store`.\n'
      ;;
    mem0)
      memory_snippet=$'- **Mem0**  \n  Cloud cross-session memory via MCP (https://github.com/mem0ai/mem0). Use `search_memories` / `add_memory` to recall and store decisions, errors, and preferences.\n'
      ;;
  esac

  case "$DOCS_TOOL" in
    qmd)
      docs_snippet=$'- **QMD**  \n  Semantic search over `docs/**`. Collection: `'"${QMD_COLLECTION}"'` → `qmd://'"${QMD_COLLECTION}"'`. Prefer `qmd search` / `qmd query -c '"${QMD_COLLECTION}"'` before bulk `.md` reads.\n'
      ;;
    graphify)
      if env_is_no "${GRAPHIFY_MCP:-}"; then
        docs_snippet=$'- **Graphify**  \n  Local knowledge graph over code/docs/media ([Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify)). Build once with `graphify .` → `graphify-out/graph.json`. CLI: `graphify query` / `graphify path` (installed without MCP extra).\n'
      else
        docs_snippet=$'- **Graphify**  \n  Local knowledge graph over code/docs/media ([Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify)). Build once with `graphify .` → `graphify-out/graph.json`. **Cursor:** MCP (`~/.cursor/mcp.json` → `python -m graphify.serve …`) + rule (`~/.cursor/rules/graphify.mdc`) — prefer `query_graph` / `get_neighbors` / `shortest_path`; CLI fallback: `graphify query` / `graphify path`.\n'
      fi
      ;;
  esac

  if [[ "$AGENT" == "antigravity" ]]; then
    cat << EOF >> "$target"

## Optimization Utilities

The following utilities are available in this environment. Agents should consider them core tools and utilize them when possible to optimize context, memory, and token usage.

- **RTK**  
  Token-compression CLI proxy (60-90% savings). Configured locally in this project workspace (no global flag).

${memory_snippet}${docs_snippet}
---

## Antigravity CLI & Workspace Guidelines

- **Workspace Rules (\`GEMINI.md\` / \`AGENTS.md\`)**: The agent automatically consults rules defined in the workspace root on startup.
- **Context Control**: Proactively use \`@\` to import specific file paths in prompts to minimize token overhead.
- **Execution Flow**: Follow the autonomous loop: **Exploration** (codebase research) → **Planning** (draft plan) → **Execution** (make changes).
- **Terminal Sandbox**: Shell commands run in a secure terminal sandbox. Safety boundaries can be tuned in \`~/.gemini/antigravity-cli/settings.json\`.
EOF
  else
    cat << EOF >> "$target"

## Optimization Utilities

The following utilities are available in this environment. Agents should consider them core tools and utilize them when possible to optimize context, memory, and token usage.

- **RTK**  
  Global utility for compressing CLI outputs before they reach the agent. Cursor: \`rtk hook cursor\` on Shell (via \`rtk init --agent cursor\`).

${memory_snippet}${docs_snippet}
---

## Usage Notes

- Use RTK for heavy Shell output.
EOF
    case "$MEMORY_TOOL" in
      icm)
        cat << EOF >> "$target"
- Use ICM for decisions/errors/preferences across sessions (\`icm recall\` / \`icm store\`).
EOF
        ;;
      mem0)
        cat << EOF >> "$target"
- Use Mem0 for decisions/errors/preferences across sessions (\`search_memories\` / \`add_memory\`).
EOF
        ;;
    esac
    if [[ "$DOCS_TOOL" == "qmd" ]]; then
      cat << EOF >> "$target"
- QMD embeddings refresh via \`.git/hooks/post-commit\` when \`docs/**\` markdown changes.
- After adding docs, run: \`qmd update && qmd embed\`
EOF
    elif [[ "$DOCS_TOOL" == "graphify" ]]; then
      cat << EOF >> "$target"
- Build the knowledge graph once: \`graphify .\` (writes \`graphify-out/graph.json\`).
- Graph rebuilds via \`.git/hooks/post-commit\` after code commits (AST-only; doc/image changes need \`graphify update .\` manually).
- Prefer Graphify MCP tools (\`query_graph\`, \`get_neighbors\`, \`shortest_path\`) over grepping; CLI fallback: \`graphify query\` / \`graphify path\`.
- After graph changes, restart Cursor if MCP was already connected, or re-run \`graphify .\`.
EOF
    fi
  fi
}

RULE_FILE="AGENTS.md"
if [[ -f "GEMINI.md" ]]; then
  RULE_FILE="GEMINI.md"
elif [[ "$AGENT" == "antigravity" ]]; then
  RULE_FILE="GEMINI.md"
fi

if [[ ! -f "$RULE_FILE" ]]; then
  echo "📄 Creating $RULE_FILE..."
  {
    echo "# $RULE_FILE"
    echo ""
  } > "$RULE_FILE"
  write_agents_compression_section "$RULE_FILE"
elif ! grep -q "## Optimization Utilities" "$RULE_FILE" && ! grep -q "## Compression Utilities" "$RULE_FILE"; then
  echo "📄 Appending optimization section to $RULE_FILE..."
  write_agents_compression_section "$RULE_FILE"
elif grep -q "^- RTK$" "$RULE_FILE" 2>/dev/null || grep -q "^- ICM$" "$RULE_FILE" 2>/dev/null || grep -q "^- Mem0$" "$RULE_FILE" 2>/dev/null || { [[ "$DOCS_TOOL" == "graphify" ]] && ! grep -q "query_graph\|graphify.serve\|Graphify MCP\|prefer \`query_graph\`" "$RULE_FILE"; }; then
  echo "📄 Upgrading Optimization Utilities section in $RULE_FILE..."
  awk '
    /^## (Compression|Optimization) Utilities/ { skip=1; next }
    skip && /^## / { skip=0 }
    skip && /^---/ { next }
    skip && /^$/ { next }
    skip && /^- / { next }
    skip && /^$/ { next }
    !skip { print }
  ' "$RULE_FILE" > "${RULE_FILE}.tmp" && mv "${RULE_FILE}.tmp" "$RULE_FILE"
  write_agents_compression_section "$RULE_FILE"
else
  echo "✅ $RULE_FILE already has an Optimization Utilities section."
fi

# -------------------------------
# Summary
# -------------------------------

echo ""
echo "🎉 Setup complete for agent: ${AGENT}"
echo "   Memory tool: ${MEMORY_TOOL}"
echo "   Docs tool: ${DOCS_TOOL}"
if [[ "$DOCS_TOOL" == "qmd" ]]; then
  echo "   QMD collection: ${QMD_COLLECTION} (qmd://${QMD_COLLECTION})"
fi
if [[ "$DOCS_TOOL" == "graphify" ]]; then
  echo "   Graphify MCP: ${GRAPHIFY_MCP:-yes}"
fi
echo ""

if [[ "$MEMORY_TOOL" == "icm" ]] && command -v icm &> /dev/null; then
  echo "📊 ICM doctor (integration health):"
  icm doctor 2>&1 | sed 's/^/   /' || true
  echo ""
fi

if [[ "$DOCS_TOOL" == "qmd" ]] && command -v qmd &> /dev/null; then
  echo "📊 QMD status:"
  qmd status 2>&1 | sed 's/^/   /' || true
  if qmd status 2>&1 | grep -qi "pending\|0 embedded\|need embedding"; then
    echo "   👉 Run: qmd update && qmd embed"
  fi
  echo ""
fi

if [[ "$AGENT" == "cursor" ]]; then
  echo "Next steps for Cursor / Cursor CLI:"
  step=1
  restart_for_mcp=0
  if [[ "$MEMORY_TOOL" == "icm" || "$MEMORY_TOOL" == "mem0" ]]; then
    restart_for_mcp=1
  fi
  if [[ "$DOCS_TOOL" == "graphify" ]] && ! env_is_no "${GRAPHIFY_MCP:-}"; then
    restart_for_mcp=1
  fi
  if [[ "$restart_for_mcp" -eq 1 ]]; then
    echo "  ${step}. Restart Cursor so MCP picks up ~/.cursor/mcp.json."
    step=$((step + 1))
  fi
  echo "  ${step}. Allow Shell(rtk) in ~/.cursor/cli-config.json if using allowlist mode."
  step=$((step + 1))
  case "$MEMORY_TOOL" in
    icm)
      echo "  ${step}. Verify ICM: icm recall \"project setup\""
      step=$((step + 1))
      ;;
    mem0)
      echo "  ${step}. Verify Mem0: search_memories for \"project setup\""
      step=$((step + 1))
      ;;
  esac
  if [[ "$DOCS_TOOL" == "qmd" ]]; then
    echo "  ${step}. Verify QMD: qmd search \"topic\" -c ${QMD_COLLECTION}"
  elif [[ "$DOCS_TOOL" == "graphify" ]]; then
    if env_is_no "${GRAPHIFY_MCP:-}"; then
      echo "  ${step}. Build graph if needed: graphify .  → then verify CLI: graphify query \"topic\""
    else
      echo "  ${step}. Build graph if needed: graphify .  → then verify MCP tool query_graph"
    fi
  fi
fi
