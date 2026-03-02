#!/usr/bin/env bash
# model-health-check.sh - detect provider overload and switch model provider automatically

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="${WATCHDOG_CONFIG:-$INSTALL_DIR/.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Shared notifications
if [[ -f "$INSTALL_DIR/lib/notify.sh" ]]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/lib/notify.sh"
fi

OPENCLAW_CMD="${OPENCLAW_CMD:-openclaw}"
STATE_DIR="${MODEL_HEALTH_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.config}/openclaw-watchdog}"
STATE_FILE="${MODEL_HEALTH_STATE_FILE:-$STATE_DIR/model-health-state.json}"
LOG_DIR="${MODEL_HEALTH_LOG_DIR:-$INSTALL_DIR/logs}"
LOG_FILE="${MODEL_HEALTH_LOG_FILE:-$LOG_DIR/model-health.log}"

PRIMARY_MODEL="${MODEL_HEALTH_PRIMARY_MODEL:-anthropic/claude-sonnet-4-6}"
FALLBACK_MODEL="${MODEL_HEALTH_FALLBACK_MODEL:-openrouter/anthropic/claude-sonnet-4-6}"
PRIMARY_FALLBACKS_CSV="${MODEL_HEALTH_PRIMARY_FALLBACKS:-openrouter/anthropic/claude-sonnet-4-6,anthropic/claude-opus-4-6,openrouter/google/gemini-2.5-pro,anthropic/claude-haiku-4-5}"
FALLBACK_FALLBACKS_CSV="${MODEL_HEALTH_FALLBACK_FALLBACKS:-openrouter/google/gemini-2.5-pro,openrouter/anthropic/claude-haiku-4-5,anthropic/claude-sonnet-4-6}"

API_BASE="${MODEL_HEALTH_API_BASE:-https://openrouter.ai/api/v1}"
PROBE_MODEL="${MODEL_HEALTH_PROBE_MODEL:-anthropic/claude-haiku-4-5}"
MODEL_HEALTH_API_KEY="${MODEL_HEALTH_API_KEY:-${OPENROUTER_API_KEY:-}}"
OVERLOAD_CODES="${MODEL_HEALTH_OVERLOAD_CODES:-529 503 502 429}"

TEST_MODE=false
if [[ "${1:-}" == "--test" ]]; then
    TEST_MODE=true
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--test]" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    STATE_DIR="$INSTALL_DIR/.state"
    STATE_FILE="${MODEL_HEALTH_STATE_FILE:-$STATE_DIR/model-health-state.json}"
    mkdir -p "$STATE_DIR"
fi

log() {
    local level="$1" message="$2"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [$level] $message" | tee -a "$LOG_FILE"
}

notify_user() {
    local message="$1"
    local title="${2:-OpenClaw Model Health}"

    if $TEST_MODE; then
        log "TEST" "Would notify: $title | $message"
        return 0
    fi

    if declare -F notify >/dev/null 2>&1; then
        notify "$message" "$title" >/dev/null 2>&1 || log "WARN" "Notification send failed"
        return 0
    fi

    log "WARN" "notify helper not available; skipping notification"
}

csv_to_json_array() {
    local csv="$1"
    local normalized

    normalized="$(printf '%s' "$csv" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')"
    if [[ -z "$normalized" ]]; then
        echo '[]'
        return 0
    fi

    printf '%s\n' "$normalized" | jq -R . | jq -s .
}

build_patch_payload() {
    local primary="$1"
    local fallbacks_csv="$2"
    local fallbacks_json

    fallbacks_json="$(csv_to_json_array "$fallbacks_csv")"
    jq -n --arg primary "$primary" --argjson fallbacks "$fallbacks_json" \
        '{agents:{defaults:{model:{primary:$primary,fallbacks:$fallbacks}}}}'
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

save_state() {
    local status="$1"
    local current_primary="$2"
    local switch_count="$3"
    local anthropic_status="${4:-null}"

    if $TEST_MODE; then
        log "TEST" "Would write state: status=$status current_primary=$current_primary switch_count=$switch_count anthropic_status=$anthropic_status"
        return 0
    fi

    jq -n \
        --arg status "$status" \
        --arg current_primary "$current_primary" \
        --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --argjson switch_count "$switch_count" \
        --argjson anthropic_status "$anthropic_status" \
        '{status:$status,current_primary:$current_primary,checked_at:$checked_at,switch_count:$switch_count,anthropic_status:$anthropic_status}' > "$STATE_FILE"
}

check_anthropic_status() {
    if [[ -z "$MODEL_HEALTH_API_KEY" ]]; then
        log "WARN" "MODEL_HEALTH_API_KEY/OPENROUTER_API_KEY is not set; health probe unavailable"
        echo "unknown"
        return 0
    fi

    local response http_status body
    response=$(curl -s -w '\n%{http_code}' \
        "$API_BASE/chat/completions" \
        -H "Authorization: Bearer $MODEL_HEALTH_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"health\"}],\"max_tokens\":1}" \
        --max-time 15 2>/dev/null || printf '\n000')

    http_status="$(printf '%s' "$response" | tail -n1)"
    body="$(printf '%s' "$response" | sed '$d')"

    if printf '%s' "$body" | grep -Eiq '"provider".*"error"|overloaded|capacity|529'; then
        http_status="529"
    fi

    log "CHECK" "Anthropic-via-OpenRouter status=$http_status"
    echo "$http_status"
}

check_fallback_status() {
    if [[ -z "$MODEL_HEALTH_API_KEY" ]]; then
        echo "unknown"
        return 0
    fi

    local http_status
    http_status=$(curl -s -o /dev/null -w '%{http_code}' \
        "$API_BASE/models" \
        -H "Authorization: Bearer $MODEL_HEALTH_API_KEY" \
        --max-time 10 2>/dev/null || echo '000')

    log "CHECK" "OpenRouter status=$http_status"
    echo "$http_status"
}

is_overload_code() {
    local code="$1"
    for overload_code in $OVERLOAD_CODES; do
        if [[ "$code" == "$overload_code" ]]; then
            return 0
        fi
    done
    return 1
}

apply_model_patch() {
    local primary="$1"
    local fallbacks_csv="$2"
    local payload

    payload="$(build_patch_payload "$primary" "$fallbacks_csv")"

    if $TEST_MODE; then
        log "TEST" "Would run: $OPENCLAW_CMD config patch '$payload'"
        return 0
    fi

    if "$OPENCLAW_CMD" config patch "$payload" >/dev/null 2>&1; then
        log "ACTION" "Model config patched: primary=$primary"
        return 0
    fi

    log "WARN" "Model patch failed; manual update may be required"
    return 1
}

main() {
    local simulated_status=""
    if $TEST_MODE; then
        simulated_status="529"
        log "TEST" "Running simulated overload test with Anthropic status=$simulated_status"
    fi

    local state prev_status switch_count
    state="$(load_state)"
    prev_status="$(printf '%s' "$state" | jq -r '.status // "ok"')"
    switch_count="$(printf '%s' "$state" | jq -r '.switch_count // 0')"

    local anthropic_status
    if $TEST_MODE; then
        anthropic_status="$simulated_status"
    else
        anthropic_status="$(check_anthropic_status)"
    fi

    if [[ "$anthropic_status" == "200" || "$anthropic_status" == "201" || "$anthropic_status" == "unknown" || "$anthropic_status" == "000" ]]; then
        if [[ "$prev_status" == "degraded" || "$prev_status" == "both_down" ]]; then
            log "RECOVERY" "Primary provider recovered; switching back to $PRIMARY_MODEL"
            apply_model_patch "$PRIMARY_MODEL" "$PRIMARY_FALLBACKS_CSV" || true
            notify_user "Primary model provider has recovered. Switched back to \`$PRIMARY_MODEL\`. Restart gateway to apply: \`openclaw gateway restart\`." "OpenClaw Model Recovered"
        else
            log "OK" "Provider healthy"
        fi

        save_state "ok" "$PRIMARY_MODEL" "$switch_count" "null"
        return 0
    fi

    if is_overload_code "$anthropic_status"; then
        if [[ "$prev_status" == "degraded" && $TEST_MODE == false ]]; then
            log "INFO" "Still degraded (status=$anthropic_status), no additional action"
            return 0
        fi

        log "WARN" "Primary provider overloaded (status=$anthropic_status); checking fallback provider"
        local fallback_status
        if $TEST_MODE; then
            fallback_status="200"
            log "TEST" "Simulated fallback status=$fallback_status"
        else
            fallback_status="$(check_fallback_status)"
        fi

        if [[ "$fallback_status" == "200" ]]; then
            log "ACTION" "Fallback healthy; switching primary to $FALLBACK_MODEL"
            apply_model_patch "$FALLBACK_MODEL" "$FALLBACK_FALLBACKS_CSV" || true
            notify_user "Primary provider overloaded (HTTP $anthropic_status). Switched to fallback model \`$FALLBACK_MODEL\`. Restart gateway to apply: \`openclaw gateway restart\`." "OpenClaw Fallback Activated"
            save_state "degraded" "$FALLBACK_MODEL" "$((switch_count + 1))" "$anthropic_status"
        else
            log "ERROR" "Fallback provider unavailable (status=$fallback_status); both providers degraded"
            notify_user "Primary provider overloaded (HTTP $anthropic_status), and fallback provider is unavailable (HTTP $fallback_status)." "OpenClaw Model Outage"
            save_state "both_down" "$FALLBACK_MODEL" "$switch_count" "$anthropic_status"
        fi

        return 0
    fi

    log "INFO" "Unhandled status ($anthropic_status); no switch performed"
    return 0
}

main "$@"
