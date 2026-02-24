#!/usr/bin/env bash
# Notification helper for openclaw-watchdog
# Usage: source lib/notify.sh && notify "Your message"

notify() {
    local message="$1"
    local title="${2:-OpenClaw Watchdog}"
    
    # Load config if not already loaded
    if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        [[ -f "$SCRIPT_DIR/../.env" ]] && source "$SCRIPT_DIR/../.env"
    fi
    
    local sent=0
    
    # Telegram
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="🔧 $title

$message" \
            -d parse_mode="Markdown" > /dev/null 2>&1
        sent=1
    fi
    
    # ntfy
    if [[ -n "$NTFY_TOPIC" ]]; then
        local ntfy_server="${NTFY_SERVER:-https://ntfy.sh}"
        curl -s -X POST "$ntfy_server/$NTFY_TOPIC" \
            -H "Title: $title" \
            -H "Priority: high" \
            -H "Tags: wrench" \
            -d "$message" > /dev/null 2>&1
        sent=1
    fi
    
    # Discord webhook
    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        curl -s -X POST "$DISCORD_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"content\": \"🔧 **$title**\\n\\n$message\"}" > /dev/null 2>&1
        sent=1
    fi
    
    if [[ $sent -eq 0 ]]; then
        echo "[WARN] No notification channels configured" >&2
        return 1
    fi
    
    return 0
}
