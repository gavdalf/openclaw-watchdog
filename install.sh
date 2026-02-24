#!/bin/bash
# OpenClaw Watchdog - Interactive Installer
# curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/openclaw-watchdog/main/install.sh | bash

set -euo pipefail

# Config
REPO_URL="https://github.com/gavdalf/openclaw-watchdog.git"
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
for cmd in git ssh curl jq; do
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
echo -e "${BLUE}Step 4: Installing${NC}"
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
echo -e "${BLUE}Step 5: Scheduler Setup${NC}"
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
echo "  View logs:      tail -f $INSTALL_DIR/logs/\$(date +%Y-%m-%d).log"
echo "  Edit config:    nano $INSTALL_DIR/.env"
echo ""
echo -e "${BLUE}What happens now:${NC}"
echo "  • Every 2 minutes, watchdog checks your gateway"
echo "  • After 2 consecutive failures, it auto-repairs"
echo "  • Before repair, it snapshots your config (git)"
echo "  • You get notified on recovery or if it needs help"
echo ""
