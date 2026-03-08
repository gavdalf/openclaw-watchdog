#!/usr/bin/env bash
# auth-sentinel.sh - monitor Anthropic OAuth token health and sync refreshed tokens into OpenClaw

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="${WATCHDOG_CONFIG:-$INSTALL_DIR/.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

if [[ -f "$INSTALL_DIR/lib/notify.sh" ]]; then
    # shellcheck source=/dev/null
    source "$INSTALL_DIR/lib/notify.sh"
fi

OPENCLAW_CMD="${OPENCLAW_CMD:-openclaw}"
STATE_DIR="${AUTH_SENTINEL_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.config}/openclaw-watchdog}"
STATE_FILE="${AUTH_SENTINEL_STATE_FILE:-$STATE_DIR/auth-sentinel-state.json}"
LOCK_DIR="${AUTH_SENTINEL_LOCK_DIR:-$STATE_DIR/auth-sentinel.lock}"
LOG_DIR="${AUTH_SENTINEL_LOG_DIR:-$INSTALL_DIR/logs}"
LOG_FILE="${AUTH_SENTINEL_LOG_FILE:-$LOG_DIR/auth-sentinel.log}"

AUTH_SENTINEL_CLAUDE_CREDS="${AUTH_SENTINEL_CLAUDE_CREDS:-$HOME/.claude/.credentials.json}"
AUTH_SENTINEL_OPENCLAW_AUTH="${AUTH_SENTINEL_OPENCLAW_AUTH:-$HOME/.openclaw/agents/main/agent/auth-profiles.json}"
AUTH_SENTINEL_GATEWAY_LOG="${AUTH_SENTINEL_GATEWAY_LOG:-$INSTALL_DIR/logs/$(date +%Y-%m-%d).log}"
AUTH_SENTINEL_REFRESH_THRESHOLD_MINS="${AUTH_SENTINEL_REFRESH_THRESHOLD_MINS:-90}"
AUTH_SENTINEL_COOLDOWN_SECS="${AUTH_SENTINEL_COOLDOWN_SECS:-300}"
AUTH_SENTINEL_OAUTH_CLIENT_ID="${AUTH_SENTINEL_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
AUTH_SENTINEL_VERIFY_MODEL="${AUTH_SENTINEL_VERIFY_MODEL:-claude-haiku-4-5}"
AUTH_SENTINEL_TOKEN_ENDPOINT="${AUTH_SENTINEL_TOKEN_ENDPOINT:-https://console.anthropic.com/v1/oauth/token}"
AUTH_SENTINEL_VERIFY_ENDPOINT="${AUTH_SENTINEL_VERIFY_ENDPOINT:-https://api.anthropic.com/v1/messages}"

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
    STATE_FILE="${AUTH_SENTINEL_STATE_FILE:-$STATE_DIR/auth-sentinel-state.json}"
    LOCK_DIR="${AUTH_SENTINEL_LOCK_DIR:-$STATE_DIR/auth-sentinel.lock}"
    mkdir -p "$STATE_DIR"
fi

log() {
    local level="$1" message="$2"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [$level] $message" | tee -a "$LOG_FILE" >&2
}

notify_user() {
    local message="$1"
    local title="${2:-OpenClaw Auth Sentinel}"

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

cleanup() {
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        trap cleanup EXIT
        return 0
    fi

    log "INFO" "Another auth-sentinel run is already active; exiting"
    exit 0
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        echo '{}'
    fi
}

save_state() {
    local last_action_epoch="$1"
    local last_action="$2"
    local last_status="${3:-ok}"
    local extra_json="${4:-{}}"

    if $TEST_MODE; then
        log "TEST" "Would write state: action=$last_action status=$last_status epoch=$last_action_epoch"
        return 0
    fi

    python3 - "$STATE_FILE" "$last_action_epoch" "$last_action" "$last_status" "$extra_json" <<'PY'
import json
import os
import sys
import tempfile

path, epoch, action, status, extra_json = sys.argv[1:]
data = {
    "last_action_epoch": int(epoch),
    "last_action": action,
    "last_status": status,
}
extra = json.loads(extra_json)
data.update(extra)

directory = os.path.dirname(path) or "."
fd, tmp_path = tempfile.mkstemp(prefix=".auth-sentinel-state.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
PY
}

cooldown_remaining() {
    local state last_action_epoch now
    state="$(load_state)"
    last_action_epoch="$(printf '%s' "$state" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_action_epoch", 0))')"
    now="$(date +%s)"

    if (( last_action_epoch <= 0 )); then
        echo 0
        return 0
    fi

    local elapsed=$((now - last_action_epoch))
    if (( elapsed >= AUTH_SENTINEL_COOLDOWN_SECS )); then
        echo 0
    else
        echo $((AUTH_SENTINEL_COOLDOWN_SECS - elapsed))
    fi
}

get_credentials_fields() {
    if $TEST_MODE; then
        python3 - <<'PY'
import json
import time
print(json.dumps({
    "access_token": "test-access-token",
    "refresh_token": "test-refresh-token",
    "expires_at_ms": int((time.time() + 120) * 1000),
}))
PY
        return 0
    fi

    python3 - "$AUTH_SENTINEL_CLAUDE_CREDS" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

oauth = data.get("claudeAiOauth") or {}
result = {
    "access_token": oauth.get("accessToken", ""),
    "refresh_token": oauth.get("refreshToken", ""),
    "expires_at_ms": int(oauth.get("expiresAt", 0) or 0),
}
print(json.dumps(result))
PY
}

update_credentials_file() {
    local access_token="$1"
    local refresh_token="$2"
    local expires_at_ms="$3"

    if [[ -z "$access_token" || -z "$refresh_token" || "$expires_at_ms" == "0" ]]; then
        log "ERROR" "Refusing to write invalid Claude credentials data"
        return 1
    fi

    if $TEST_MODE; then
        log "TEST" "Would update credentials file at $AUTH_SENTINEL_CLAUDE_CREDS"
        return 0
    fi

    python3 - "$AUTH_SENTINEL_CLAUDE_CREDS" "$access_token" "$refresh_token" "$expires_at_ms" <<'PY'
import json
import os
import sys
import tempfile

path, access_token, refresh_token, expires_at_ms = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

oauth = data.setdefault("claudeAiOauth", {})
oauth["accessToken"] = access_token
oauth["refreshToken"] = refresh_token
oauth["expiresAt"] = int(expires_at_ms)

directory = os.path.dirname(path) or "."
fd, tmp_path = tempfile.mkstemp(prefix=".credentials.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
PY
}

update_openclaw_auth_file() {
    local access_token="$1"

    if [[ -z "$access_token" ]]; then
        log "ERROR" "Refusing to write blank token into OpenClaw auth profiles"
        return 1
    fi

    if $TEST_MODE; then
        log "TEST" "Would write OpenClaw auth profiles to $AUTH_SENTINEL_OPENCLAW_AUTH"
        return 0
    fi

    mkdir -p "$(dirname "$AUTH_SENTINEL_OPENCLAW_AUTH")"
    python3 - "$AUTH_SENTINEL_OPENCLAW_AUTH" "$access_token" <<'PY'
import json
import os
import sys
import tempfile

path, access_token = sys.argv[1:]

# Merge with existing data instead of overwriting (preserves other profiles, usageStats, etc.)
data = {"version": 1, "profiles": {}, "lastGood": {}, "usageStats": {}}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        pass

if "profiles" not in data:
    data["profiles"] = {}
if "lastGood" not in data:
    data["lastGood"] = {}

data["profiles"]["anthropic:manual"] = {
    "type": "token",
    "provider": "anthropic",
    "token": access_token,
}
data["lastGood"]["anthropic"] = "anthropic:manual"

directory = os.path.dirname(path) or "."
fd, tmp_path = tempfile.mkstemp(prefix=".auth-profiles.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
PY
}

refresh_oauth_token() {
    local refresh_token="$1"
    local response http_status body

    if [[ -z "$refresh_token" ]]; then
        log "ERROR" "Refresh token is missing; cannot refresh Anthropic OAuth token"
        return 1
    fi

    if $TEST_MODE; then
        python3 - <<'PY'
import json
import time
print(json.dumps({
    "access_token": "test-refreshed-access-token",
    "refresh_token": "test-refresh-token",
    "expires_at_ms": int((time.time() + 7200) * 1000),
}))
PY
        return 0
    fi

    response="$(curl -sS -w '\n%{http_code}' "$AUTH_SENTINEL_TOKEN_ENDPOINT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=refresh_token&refresh_token=$refresh_token&client_id=$AUTH_SENTINEL_OAUTH_CLIENT_ID" \
        --max-time 20 2>/dev/null || printf '\n000')"

    http_status="$(printf '%s' "$response" | tail -n1)"
    body="$(printf '%s' "$response" | sed '$d')"
    log "CHECK" "OAuth refresh endpoint status=$http_status"

    if [[ "$http_status" != "200" && "$http_status" != "201" ]]; then
        log "ERROR" "OAuth refresh failed with status=$http_status"
        return 1
    fi

    python3 - "$body" "$refresh_token" <<'PY'
import json
import sys
import time

body, existing_refresh = sys.argv[1:]
data = json.loads(body or "{}")
access_token = data.get("access_token") or data.get("accessToken") or ""
refresh_token = data.get("refresh_token") or data.get("refreshToken") or existing_refresh
expires_in = data.get("expires_in") or data.get("expiresIn")
expires_at = data.get("expires_at") or data.get("expiresAt")

if not access_token:
    raise SystemExit(1)

if expires_at is not None:
    try:
        expires_at_ms = int(expires_at)
        if expires_at_ms < 10_000_000_000:
            expires_at_ms *= 1000
    except Exception:
        raise SystemExit(1)
elif expires_in is not None:
    expires_at_ms = int((time.time() + int(expires_in)) * 1000)
else:
    expires_at_ms = int((time.time() + 3600) * 1000)

print(json.dumps({
    "access_token": access_token,
    "refresh_token": refresh_token,
    "expires_at_ms": expires_at_ms,
}))
PY
}

verify_token() {
    local access_token="$1"
    local response http_status

    if [[ -z "$access_token" ]]; then
        log "ERROR" "Cannot verify blank access token"
        return 1
    fi

    if $TEST_MODE; then
        log "TEST" "Would verify token against $AUTH_SENTINEL_VERIFY_ENDPOINT using model=$AUTH_SENTINEL_VERIFY_MODEL"
        echo "200"
        return 0
    fi

    response="$(curl -sS -w '\n%{http_code}' "$AUTH_SENTINEL_VERIFY_ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "x-api-key: $access_token" \
        -d "{\"model\":\"$AUTH_SENTINEL_VERIFY_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"health\"}]}" \
        --max-time 20 2>/dev/null || printf '\n000')"

    http_status="$(printf '%s' "$response" | tail -n1)"
    log "CHECK" "Anthropic verify status=$http_status"
    echo "$http_status"
}

count_recent_oauth_401s() {
    if [[ ! -f "$AUTH_SENTINEL_GATEWAY_LOG" ]]; then
        echo 0
        return 0
    fi

    tail -n 100 "$AUTH_SENTINEL_GATEWAY_LOG" | python3 -c '
import re
import sys

pattern = re.compile(r"(oauth|anthropic|token|unauthori[sz]ed).*(401|invalid)", re.I)
reverse = re.compile(r"(401|invalid).*(oauth|anthropic|token|unauthori[sz]ed)", re.I)
count = 0
for line in sys.stdin:
    if pattern.search(line) or reverse.search(line):
        count += 1
print(count)
'
}

trigger_openclaw_reload() {
    if $TEST_MODE; then
        log "TEST" "Would run: $OPENCLAW_CMD secrets reload"
        return 0
    fi

    if "$OPENCLAW_CMD" secrets reload >/dev/null 2>&1; then
        log "ACTION" "OpenClaw secrets reloaded"
        return 0
    fi

    log "WARN" "OpenClaw secrets reload failed"
    return 1
}

signal_gateway_restart() {
    local pid
    if $TEST_MODE; then
        pid="$(pgrep -f 'openclaw gateway' | head -n1 || true)"
        pid="${pid:-unknown}"
        log "TEST" "Would send SIGUSR1 to gateway pid=$pid"
        return 0
    fi

    pid="$(pgrep -f 'openclaw gateway' | head -n1 || true)"
    if [[ -z "$pid" ]]; then
        log "WARN" "OpenClaw gateway process not found for SIGUSR1"
        return 1
    fi

    kill -USR1 "$pid"
    log "ACTION" "Sent SIGUSR1 to gateway pid=$pid"
}

perform_refresh_cycle() {
    local reason="$1"
    local allow_retry="$2"
    local credentials_json refresh_token refresh_json access_token new_refresh_token expires_at_ms verify_status now extra_json

    credentials_json="$(get_credentials_fields)" || {
        log "ERROR" "Unable to read Claude credentials from $AUTH_SENTINEL_CLAUDE_CREDS"
        notify_user "Auth sentinel could not read Claude credentials at \`$AUTH_SENTINEL_CLAUDE_CREDS\`." "OpenClaw Auth Sentinel Error"
        return 1
    }
    refresh_token="$(printf '%s' "$credentials_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("refresh_token", ""))')"

    log "ACTION" "Starting token refresh cycle: reason=$reason"
    refresh_json="$(refresh_oauth_token "$refresh_token")" || {
        notify_user "OAuth token refresh failed for reason: $reason" "OpenClaw Auth Refresh Failed"
        return 1
    }

    access_token="$(printf '%s' "$refresh_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token", ""))')"
    new_refresh_token="$(printf '%s' "$refresh_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("refresh_token", ""))')"
    expires_at_ms="$(printf '%s' "$refresh_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expires_at_ms", 0))')"

    if [[ -z "$access_token" || -z "$new_refresh_token" || "$expires_at_ms" == "0" ]]; then
        log "ERROR" "Refresh response did not include valid token data"
        notify_user "Received invalid token data from the OAuth refresh endpoint." "OpenClaw Auth Refresh Failed"
        return 1
    fi

    update_credentials_file "$access_token" "$new_refresh_token" "$expires_at_ms"
    update_openclaw_auth_file "$access_token"
    trigger_openclaw_reload || true
    signal_gateway_restart || true

    verify_status="$(verify_token "$access_token")"
    if [[ "$verify_status" == "200" || "$verify_status" == "201" ]]; then
        now="$(date +%s)"
        extra_json="$(python3 - "$expires_at_ms" "$verify_status" <<'PY'
import json
import sys
expires_at_ms, verify_status = sys.argv[1:]
print(json.dumps({
    "expires_at_ms": int(expires_at_ms),
    "last_verify_status": verify_status,
}))
PY
)"
        save_state "$now" "$reason" "refreshed" "$extra_json"
        notify_user "OAuth token refreshed, synced into OpenClaw, and verified successfully." "OpenClaw Auth Refreshed"
        log "OK" "Refresh cycle completed successfully"
        return 0
    fi

    if [[ "$verify_status" == "401" && "$allow_retry" == "true" ]]; then
        log "WARN" "Verification returned 401; attempting emergency re-refresh"
        perform_refresh_cycle "verification-401" "false"
        return $?
    fi

    now="$(date +%s)"
    extra_json="$(python3 - "$expires_at_ms" "$verify_status" <<'PY'
import json
import sys
expires_at_ms, verify_status = sys.argv[1:]
print(json.dumps({
    "expires_at_ms": int(expires_at_ms),
    "last_verify_status": verify_status,
}))
PY
)"
    save_state "$now" "$reason" "verify_failed" "$extra_json"
    log "ERROR" "Token verification failed after sync with status=$verify_status"
    notify_user "OAuth token was refreshed and synced, but Anthropic verification failed with HTTP $verify_status." "OpenClaw Auth Verify Failed"
    return 1
}

main() {
    acquire_lock

    if ! command -v python3 >/dev/null 2>&1; then
        log "ERROR" "python3 is required"
        exit 1
    fi

    local auth_401_count cooldown expiry_status credentials_json expires_at_ms now threshold_secs seconds_left reason
    auth_401_count="$(count_recent_oauth_401s)"
    log "CHECK" "Recent OAuth 401 count=$auth_401_count"

    if $TEST_MODE; then
        log "TEST" "Running simulated expiry test"
        perform_refresh_cycle "test-mode" "true"
        return 0
    fi

    credentials_json="$(get_credentials_fields)" || {
        log "ERROR" "Unable to read Claude credentials from $AUTH_SENTINEL_CLAUDE_CREDS"
        notify_user "Auth sentinel could not read Claude credentials at \`$AUTH_SENTINEL_CLAUDE_CREDS\`." "OpenClaw Auth Sentinel Error"
        exit 1
    }
    expires_at_ms="$(printf '%s' "$credentials_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expires_at_ms", 0))')"
    now="$(date +%s)"
    threshold_secs=$((AUTH_SENTINEL_REFRESH_THRESHOLD_MINS * 60))
    seconds_left=$(( (expires_at_ms / 1000) - now ))

    expiry_status="healthy"
    if (( expires_at_ms <= 0 )); then
        expiry_status="invalid"
    elif (( seconds_left <= 0 )); then
        expiry_status="expired"
    elif (( seconds_left <= threshold_secs )); then
        expiry_status="expiring_soon"
    fi

    log "CHECK" "Token expiry status=$expiry_status seconds_left=$seconds_left threshold_secs=$threshold_secs"

    reason=""
    if (( auth_401_count >= 2 )); then
        reason="gateway-401-pattern"
    elif [[ "$expiry_status" == "expired" || "$expiry_status" == "expiring_soon" || "$expiry_status" == "invalid" ]]; then
        reason="token-$expiry_status"
    fi

    if [[ -z "$reason" ]]; then
        log "OK" "Token healthy; no action required"
        return 0
    fi

    cooldown="$(cooldown_remaining)"
    if (( cooldown > 0 )); then
        log "INFO" "Cooldown active for ${cooldown}s; skipping action reason=$reason"
        return 0
    fi

    perform_refresh_cycle "$reason" "true"
}

main "$@"
