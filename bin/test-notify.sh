#!/usr/bin/env bash
# Test notification channels
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/notify.sh"

message="${1:-Test notification from openclaw-watchdog}"

echo "Sending test notification..."
if notify "$message" "Test Alert"; then
    echo "✅ Notification sent successfully"
else
    echo "❌ Failed to send notification (no channels configured?)"
    exit 1
fi
