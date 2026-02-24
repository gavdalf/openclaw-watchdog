#!/bin/bash
# OpenClaw Watchdog - Gateway Health Monitor
# https://github.com/gavinwhittaker/openclaw-watchdog

set -euo pipefail

# Determine install directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
CONFIG_FILE="${WATCHDOG_CONFIG:-$INSTALL_DIR/.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi

# Required settings
SSH_HOST="${SSH_HOST:-}"
SSH_USER="${SSH_USER:-root}"
SSH_KEY="${SSH_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"

if [[ -z "$SSH_HOST" ]]; then
    echo "ERROR: SSH_HOST not configured in $CONFIG_FILE" >&2
    exit 1
fi

# Build SSH command
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
[[ -n "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
SSH_CMD="ssh $SSH_OPTS -p $SSH_PORT ${SSH_USER}@${SSH_HOST}"

# Paths
FAIL_FILE="$INSTALL_DIR/.failure-count"
LOG_DIR="$INSTALL_DIR/logs"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

# Behavior settings
MAX_REPAIR_ATTEMPTS="${MAX_REPAIR_ATTEMPTS:-2}"
ENABLE_CONFIG_BACKUP="${ENABLE_CONFIG_BACKUP:-true}"
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-~/.openclaw}"

# Notifications
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

# Ensure log dir exists
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# === Logging ===
log() {
    local level="$1" message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

log_audit() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AUDIT: $1 | $2" >> "$LOG_DIR/audit.log"
}

# === Notifications ===
notify() {
    local message="$1"
    local title="${2:-OpenClaw Watchdog}"
    local sent=0
    
    # Telegram
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="🔧 $title

$message" >/dev/null 2>&1 && sent=1
    fi
    
    # ntfy
    if [[ -n "$NTFY_TOPIC" ]]; then
        curl -s -X POST "$NTFY_SERVER/$NTFY_TOPIC" \
            -H "Title: $title" -H "Priority: high" -H "Tags: wrench" \
            -d "$message" >/dev/null 2>&1 && sent=1
    fi
    
    # Discord
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        curl -s -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"content\": \"🔧 **$title**\\n\\n$message\"}" >/dev/null 2>&1 && sent=1
    fi
    
    [[ $sent -eq 1 ]] && log_audit "NOTIFY" "Sent: $message"
}

# === Config Backup (git-based) ===
backup_config() {
    if [[ "$ENABLE_CONFIG_BACKUP" != "true" ]]; then
        return 0
    fi
    
    log "BACKUP" "Creating pre-repair config snapshot..."
    
    # Check if openclaw config dir is a git repo, init if not
    $SSH_CMD "cd $OPENCLAW_CONFIG_DIR && \
        if [[ ! -d .git ]]; then \
            git init && \
            git add -A && \
            git commit -m 'Initial config snapshot' 2>/dev/null || true; \
        fi && \
        git add -A && \
        git diff --staged --quiet || git commit -m 'Pre-repair snapshot $(date +%Y-%m-%d_%H:%M:%S)'" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        log "BACKUP" "Config snapshot created"
        log_audit "BACKUP" "Git commit created in $OPENCLAW_CONFIG_DIR"
    else
        log "WARN" "Config backup failed (non-fatal)"
    fi
}

# === Health Check ===
check_health() {
    local health_json
    health_json=$($SSH_CMD "openclaw health --json" 2>/dev/null) || return 1
    
    echo "$health_json" | jq -e '.healthy == true' >/dev/null 2>&1
}

# === Repair ===
run_repair() {
    log "REPAIR" "Running openclaw doctor --repair --yes"
    log_audit "REPAIR" "Initiating auto-repair"
    
    # Backup config first
    backup_config
    
    # Run doctor
    local output
    output=$($SSH_CMD "openclaw doctor --repair --yes" 2>&1) || true
    
    log "REPAIR" "Doctor output: $output"
    
    # Check if healthy now
    sleep 5
    if check_health; then
        return 0
    else
        return 1
    fi
}

# === Failure Counter ===
get_failure_count() {
    [[ -f "$FAIL_FILE" ]] && cat "$FAIL_FILE" || echo "0"
}

set_failure_count() {
    echo "$1" > "$FAIL_FILE"
}

reset_failure_count() {
    set_failure_count 0
}

# === Main ===
main() {
    log "CHECK" "Starting health check for $SSH_HOST"
    
    if check_health; then
        log "OK" "Gateway healthy"
        reset_failure_count
        exit 0
    fi
    
    # Unhealthy
    local failures=$(get_failure_count)
    failures=$((failures + 1))
    set_failure_count $failures
    
    log "WARN" "Health check failed (attempt $failures/$MAX_REPAIR_ATTEMPTS)"
    
    if [[ $failures -ge $MAX_REPAIR_ATTEMPTS ]]; then
        log "REPAIR" "Threshold reached, attempting repair..."
        
        if run_repair; then
            log "OK" "Repair successful! Gateway recovered."
            notify "✅ Gateway was down but auto-repair fixed it. All good now."
            reset_failure_count
        else
            log "ERROR" "Repair failed. Manual intervention needed."
            notify "🚨 Gateway is DOWN. Auto-repair failed. Manual intervention required.\n\nHost: $SSH_HOST\nLogs: $LOG_FILE"
            # Don't reset counter - will retry on next check
        fi
    else
        log "INFO" "Waiting for next check (failure $failures/$MAX_REPAIR_ATTEMPTS)"
    fi
}

main "$@"
