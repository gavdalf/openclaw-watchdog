#!/bin/bash
# OpenClaw Watchdog - Interactive Installer
# curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/openclaw-watchdog/main/install.sh | bash

set -euo pipefail

# Config
REPO_URL="https://github.com/openclaw/openclaw-watchdog.git"
VERSION="main"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
cat << 'BANNER'
   ___                   _____ _                 
  / _ \ _ __   ___ _ __ / ____| | __ ___      __ 
 | | | | '_ \ / _ \ '_ \| |    | |/ _` \ \ /\ / / 
 | |_| | |_) |  __/ | | | |____| | (_| |\ V  V /  
  \___/| .__/ \___|_| |_|\_____|_|\__,_| \_/\_/   
       |_|          WATCHDOG                      
BANNER
echo -e "${NC}"
echo "Self-healing monitor for your OpenClaw gateway"
echo "================================================"
echo ""

# Check dependencies
for cmd in git ssh curl jq python3; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}Missing required command: $cmd${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✓${NC} Dependencies OK"

# Detect platform
OS=$(uname -s)
case "$OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      echo -e "${RED}Unsupported OS: $OS. Use WSL2 on Windows.${NC}"; exit 1 ;;
esac
echo -e "${GREEN}✓${NC} Platform: $PLATFORM"

# Set install path
if [[ "$PLATFORM" == "macos" ]]; then
    INSTALL_DIR="$HOME/.local/share/openclaw-watchdog"
else
    INSTALL_DIR="$HOME/.local/share/openclaw-watchdog"
fi

echo ""
echo -e "${BLUE}Step 1: OpenClaw Host Connection${NC}"
echo "---------------------------------"
read -p "SSH host (hostname or IP of your OpenClaw server): " SSH_HOST
read -p "SSH user [root]: " SSH_USER
SSH_USER=${SSH_USER:-root}
read -p "SSH port [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

echo ""
echo -e "${BLUE}Step 2: SSH Key Setup${NC}"
echo "---------------------"
SSH_KEY="$HOME/.ssh/openclaw-watchdog"

if [[ -f "$SSH_KEY" ]]; then
    echo -e "${GREEN}✓${NC} SSH key exists: $SSH_KEY"
else
    echo "Generating dedicated SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "openclaw-watchdog"
    echo -e "${GREEN}✓${NC} SSH key created"
fi

PUB_KEY=$(cat "${SSH_KEY}.pub")
echo ""
echo -e "${YELLOW}ACTION REQUIRED:${NC} Add this key to your OpenClaw server:"
echo ""
echo -e "${BLUE}echo '$PUB_KEY' >> ~/.ssh/authorized_keys${NC}"
echo ""
read -p "Press Enter once done..."

# Test connection
echo "Testing SSH connection..."
if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" 'openclaw --version' 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Connection successful, OpenClaw found"
else
    echo -e "${RED}✗${NC} Connection failed. Check host, key, and that OpenClaw is installed."
    exit 1
fi

echo ""
echo -e "${BLUE}Step 3: Notifications (optional)${NC}"
echo "---------------------------------"
echo "Configure at least one to get alerts when things break."
echo ""

read -p "Telegram Bot Token (from @BotFather, or Enter to skip): " TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=""
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
    read -p "Telegram Chat ID (your user ID or group ID): " TELEGRAM_CHAT_ID
fi

read -p "ntfy topic (e.g., my-watchdog-alerts, or Enter to skip): " NTFY_TOPIC
read -p "Discord webhook URL (or Enter to skip): " DISCORD_WEBHOOK_URL

echo ""
echo -e "${BLUE}Step 4: Model Health Fallback${NC}"
echo "-----------------------------"
echo "Model Health Check monitors Anthropic overload (HTTP 529) and can switch to a fallback model."
read -p "Preferred fallback model [openrouter/anthropic/claude-sonnet-4-6]: " MODEL_HEALTH_FALLBACK_MODEL
MODEL_HEALTH_FALLBACK_MODEL=${MODEL_HEALTH_FALLBACK_MODEL:-openrouter/anthropic/claude-sonnet-4-6}

echo ""
echo -e "${BLUE}Step 5: Auth Sentinel (optional)${NC}"
echo "--------------------------------"
read -p "Enable Anthropic OAuth monitoring? [y/N]: " ENABLE_AUTH_SENTINEL_INPUT
ENABLE_AUTH_SENTINEL="false"
AUTH_SENTINEL_CLAUDE_CREDS="$HOME/.claude/.credentials.json"
AUTH_SENTINEL_OPENCLAW_AUTH="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
AUTH_SENTINEL_GATEWAY_LOG="$INSTALL_DIR/logs/$(date +%Y-%m-%d).log"
if [[ "$ENABLE_AUTH_SENTINEL_INPUT" =~ ^[Yy]$ ]]; then
    ENABLE_AUTH_SENTINEL="true"
    read -p "Claude credentials path [$AUTH_SENTINEL_CLAUDE_CREDS]: " AUTH_SENTINEL_CLAUDE_CREDS_INPUT
    AUTH_SENTINEL_CLAUDE_CREDS=${AUTH_SENTINEL_CLAUDE_CREDS_INPUT:-$AUTH_SENTINEL_CLAUDE_CREDS}
    read -p "OpenClaw auth-profiles path [$AUTH_SENTINEL_OPENCLAW_AUTH]: " AUTH_SENTINEL_OPENCLAW_AUTH_INPUT
    AUTH_SENTINEL_OPENCLAW_AUTH=${AUTH_SENTINEL_OPENCLAW_AUTH_INPUT:-$AUTH_SENTINEL_OPENCLAW_AUTH}
fi

echo ""
echo -e "${BLUE}Step 6: Installing${NC}"
echo "------------------"

# Clone or update repo
if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "Updating existing installation..."
    cd "$INSTALL_DIR"
    git pull --ff-only
else
    echo "Cloning repository..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 -b "$VERSION" "$REPO_URL" "$INSTALL_DIR"
fi
echo -e "${GREEN}✓${NC} Files installed to $INSTALL_DIR"

# Create logs directory
mkdir -p "$INSTALL_DIR/logs"
chmod 700 "$INSTALL_DIR/logs"

# Generate .env config
cat > "$INSTALL_DIR/.env" << ENVFILE
# OpenClaw Watchdog Configuration
# Generated: $(date)

# SSH Connection
SSH_HOST="$SSH_HOST"
SSH_USER="$SSH_USER"
SSH_KEY="$SSH_KEY"
SSH_PORT="$SSH_PORT"

# Notifications
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
NTFY_TOPIC="$NTFY_TOPIC"
DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"

# Behavior
MAX_REPAIR_ATTEMPTS="2"
ENABLE_CONFIG_BACKUP="true"
OPENCLAW_CONFIG_DIR="~/.openclaw"

# Model Health Check
MODEL_HEALTH_PRIMARY_MODEL="anthropic/claude-sonnet-4-6"
MODEL_HEALTH_FALLBACK_MODEL="$MODEL_HEALTH_FALLBACK_MODEL"
MODEL_HEALTH_PROBE_MODEL="anthropic/claude-haiku-4-5"
# Optional override, defaults to OPENROUTER_API_KEY if unset
MODEL_HEALTH_API_KEY=""

# Auth Sentinel
ENABLE_AUTH_SENTINEL="$ENABLE_AUTH_SENTINEL"
AUTH_SENTINEL_CLAUDE_CREDS="$AUTH_SENTINEL_CLAUDE_CREDS"
AUTH_SENTINEL_OPENCLAW_AUTH="$AUTH_SENTINEL_OPENCLAW_AUTH"
AUTH_SENTINEL_GATEWAY_LOG="$AUTH_SENTINEL_GATEWAY_LOG"
AUTH_SENTINEL_REFRESH_THRESHOLD_MINS="90"
AUTH_SENTINEL_COOLDOWN_SECS="300"
AUTH_SENTINEL_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTH_SENTINEL_VERIFY_MODEL="claude-haiku-4-5"
ENVFILE
chmod 600 "$INSTALL_DIR/.env"
echo -e "${GREEN}✓${NC} Config written"

# Test notification if configured
if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    echo "Sending test notification..."
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="🐕 OpenClaw Watchdog installed! Monitoring is now active." >/dev/null && \
    echo -e "${GREEN}✓${NC} Test notification sent"
fi

echo ""
echo -e "${BLUE}Step 7: Scheduler Setup${NC}"
echo "-----------------------"

if [[ "$PLATFORM" == "macos" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.openclaw.watchdog.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" << PLISTFILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/bin/watchdog-check.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/logs/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/logs/stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
PLISTFILE
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo -e "${GREEN}✓${NC} LaunchAgent installed (runs every 2 minutes)"
    
else
    # Linux systemd
    mkdir -p "$HOME/.config/systemd/user"
    
    cat > "$HOME/.config/systemd/user/openclaw-watchdog.service" << SVCFILE
[Unit]
Description=OpenClaw Watchdog Health Check

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/watchdog-check.sh
SVCFILE

    cat > "$HOME/.config/systemd/user/openclaw-watchdog.timer" << TIMERFILE
[Unit]
Description=Run OpenClaw Watchdog every 2 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=120

[Install]
WantedBy=timers.target
TIMERFILE

    systemctl --user daemon-reload
    systemctl --user enable --now openclaw-watchdog.timer
    echo -e "${GREEN}✓${NC} Systemd timer installed (runs every 2 minutes)"
fi

echo ""
echo -e "${BLUE}Step 8: Model Health Cron Setup${NC}"
echo "--------------------------------"
if command -v crontab >/dev/null 2>&1; then
    CRON_MARKER="# openclaw-watchdog-model-health"
    CRON_CMD="WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/model-health-check.sh >> $INSTALL_DIR/logs/model-health-cron.log 2>&1"
    (
        crontab -l 2>/dev/null | grep -v "openclaw-watchdog-model-health" || true
        echo "*/5 * * * * $CRON_CMD $CRON_MARKER"
    ) | crontab -
    echo -e "${GREEN}✓${NC} Cron entry installed (every 5 minutes)"
    echo "  It detects Anthropic overload (HTTP 529), switches to your fallback model, and switches back on recovery."
else
    echo -e "${YELLOW}⚠${NC} crontab command not found. Add this manually:"
    echo "  */5 * * * * WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/model-health-check.sh >> $INSTALL_DIR/logs/model-health-cron.log 2>&1 # openclaw-watchdog-model-health"
fi

echo ""
echo -e "${BLUE}Step 9: Auth Sentinel Cron Setup${NC}"
echo "--------------------------------"
if [[ "$ENABLE_AUTH_SENTINEL" != "true" ]]; then
    echo "Skipped. OAuth monitoring not enabled."
elif command -v crontab >/dev/null 2>&1; then
    CRON_MARKER="# openclaw-watchdog-auth-sentinel"
    CRON_CMD="WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/auth-sentinel.sh >> $INSTALL_DIR/logs/auth-sentinel-cron.log 2>&1"
    (
        crontab -l 2>/dev/null | grep -v "openclaw-watchdog-auth-sentinel" || true
        echo "*/5 * * * * $CRON_CMD $CRON_MARKER"
    ) | crontab -
    echo -e "${GREEN}✓${NC} Cron entry installed (every 5 minutes)"
    echo "  It refreshes expiring Anthropic OAuth tokens, syncs OpenClaw auth profiles, reloads secrets, and verifies the token."
else
    echo -e "${YELLOW}⚠${NC} crontab command not found. Add this manually:"
    echo "  */5 * * * * WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/auth-sentinel.sh >> $INSTALL_DIR/logs/auth-sentinel-cron.log 2>&1 # openclaw-watchdog-auth-sentinel"
fi

# Done!
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Installation Complete! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Watchdog is now monitoring: $SSH_HOST"
echo ""
echo "Useful commands:"
echo "  Manual check:   $INSTALL_DIR/bin/watchdog-check.sh"
echo "  Model check:    WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/model-health-check.sh"
echo "  Model test:     WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/model-health-check.sh --test"
echo "  Auth check:     WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/auth-sentinel.sh"
echo "  Auth test:      WATCHDOG_CONFIG=$INSTALL_DIR/.env $INSTALL_DIR/bin/auth-sentinel.sh --test"
echo "  View logs:      tail -f $INSTALL_DIR/logs/\$(date +%Y-%m-%d).log"
echo "  Edit config:    nano $INSTALL_DIR/.env"
echo ""
echo -e "${BLUE}What happens now:${NC}"
echo "  • Every 2 minutes, watchdog checks your gateway"
echo "  • After 2 consecutive failures, it auto-repairs"
echo "  • Before repair, it snapshots your config (git)"
echo "  • You get notified on recovery or if it needs help"
echo "  • Every 5 minutes, model-health-check handles Anthropic overload failover/recovery"
if [[ "$ENABLE_AUTH_SENTINEL" == "true" ]]; then
echo "  • Every 5 minutes, auth-sentinel refreshes expiring Anthropic OAuth tokens and syncs them into OpenClaw"
fi
echo ""
