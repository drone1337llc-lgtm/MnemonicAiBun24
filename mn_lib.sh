#!/usr/bin/env bash
# mn_lib.sh — shared config, sourced by all other mn_*.sh scripts.
# Edit this file when paths or alert destinations change. Don't edit the others.

# ---------- paths ----------
export MN_REPO="${MN_REPO:-$HOME/MnemonicAi}"
export MN_VENV="$MN_REPO/mnemonicai_venv"
export MN_DATA="$MN_REPO/mnemonicai_data"
export MN_LOGS="$MN_DATA/logs"
export MN_ROLES="$MN_REPO/.mn_gpu_roles"
export MN_ENV_FILE="$MN_REPO/mn_env.json"
export MN_PID="$MN_REPO/mn_run.pid"
export MN_PORT="${MN_PORT:-8400}"
export MN_HOST="${MN_HOST:-0.0.0.0}"

# adapter registry
export MN_ADAPTER_DIR="$MN_DATA/adapter"
export MN_ADAPTER_REGISTRY="$MN_ADAPTER_DIR/.registry.json"

# ---------- backup destinations ----------
export MN_BACKUP_LOCAL="$MN_DATA/backups"
export MN_BACKUP_OFFSITE="${MN_BACKUP_OFFSITE:-/mnt/nas/mnemonicai_backups}"
export MN_BACKUP_KEEP_DAILY=7
export MN_BACKUP_KEEP_WEEKLY=4
export MN_BACKUP_KEEP_MONTHLY=6
export MN_BACKUP_THREADS="${MN_BACKUP_THREADS:-4}"

# ---------- alert destinations ----------
export MN_ALERT_EMAIL="${MN_ALERT_EMAIL:-}"
export MN_ALERT_WEBHOOK="${MN_ALERT_WEBHOOK:-}"

# ---------- fleet ----------
export MN_FLEET="${MN_FLEET:-}"

# ---------- helpers ----------
_mn_log() { printf "[\033[0;36m%s\033[0m] %s\n" "$(date +%H:%M:%S)" "$*"; }
_mn_err() { printf "[\033[0;31m%s\033[0m] %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
_mn_ok()  { printf "[\033[0;32m%s\033[0m] %s\n" "$(date +%H:%M:%S)" "$*"; }

mn_alert() {
  local subject="$1" body="$2"
  [ -z "$MN_ALERT_EMAIL" ] && [ -z "$MN_ALERT_WEBHOOK" ] && return 0
  if [ -n "$MN_ALERT_EMAIL" ] && command -v mail >/dev/null 2>&1; then
    printf "%s\n\n— mn-watch on %s\n" "$body" "$(hostname)" \
      | mail -s "[$subject] $(hostname)" "$MN_ALERT_EMAIL" 2>/dev/null || true
  fi
  if [ -n "$MN_ALERT_WEBHOOK" ] && command -v curl >/dev/null 2>&1; then
    # Escape quotes and newlines for safe JSON payload
    local escaped_body
    escaped_body=$(printf '%s' "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    local payload="{\"text\":\"[$subject] $(hostname): $escaped_body\"}"
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" \
      "$MN_ALERT_WEBHOOK" 2>/dev/null || true
  elif [ -n "$MN_ALERT_WEBHOOK" ] && ! command -v curl >/dev/null 2>&1; then
    _mn_err "curl not found — cannot send webhook alert. Install: sudo apt-get install -y curl"
  fi
}

_mn_check_deps() {
  for cmd in tar zstd rsync; do
    command -v "$cmd" >/dev/null 2>&1 || {
      _mn_err "missing dependency: $cmd — sudo apt-get install -y $cmd"
      return 1
    }
  done
}
