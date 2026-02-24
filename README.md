# openclaw-watchdog

> Self-healing monitoring for OpenClaw gateways. Runs out-of-band, detects failures, auto-repairs.

## How It Works

The watchdog runs on a **separate machine** from your OpenClaw instance. This "out-of-band" design means if your gateway crashes, the watchdog is still alive to detect and fix it.

```
┌─────────────────────┐         SSH          ┌─────────────────────┐
│   WATCHDOG HOST     │ ──────────────────▶  │   OPENCLAW HOST     │
│   (Mac/Linux/WSL)   │                      │   (VPS/Server)      │
│                     │   openclaw health    │                     │
│   Runs every 2 min  │ ◀────────────────── │   Your gateway      │
│   Detects failures  │        JSON          │   lives here        │
│   Triggers repairs  │                      │                     │
└─────────────────────┘                      └─────────────────────┘

         │                                            │
         │  If unhealthy:                             │
         │  1. Try: openclaw doctor --repair          │
         │  2. If still broken: notify you            │
         └────────────────────────────────────────────┘
```

## Recovery Tiers

| Tier | Action | Cost |
|------|--------|------|
| 1 | `openclaw health --json` | Free (fast check) |
| 2 | `openclaw doctor --repair --yes` | Free (auto-fix) |
| 3 | Notification (Telegram/Discord/ntfy) | Free |
| 4 | Claude Code diagnosis (future) | ~$0.10 per incident |

Most issues are fixed at Tier 2 without any LLM cost.

## Requirements

- **Watchdog machine:** macOS, Linux, or Windows (via WSL2)
- **SSH access** to your OpenClaw host (key-based auth recommended)
- **OpenClaw CLI** installed on the target host
- **(Optional)** Telegram bot token for notifications

## Quick Install

```bash
# Clone the repo
git clone https://github.com/gavdalf/openclaw-watchdog.git
cd openclaw-watchdog

# Run installer (auto-detects macOS/Linux, sets up scheduler)
./install.sh
```

The installer will:
1. Prompt for your OpenClaw host details (SSH user, host, key path)
2. Set up the health check script
3. Configure the scheduler (launchd on macOS, systemd on Linux)
4. Optionally configure Telegram notifications

## Configuration

All settings live in `.env`:

```bash
# SSH connection to your OpenClaw host
SSH_USER="root"
SSH_HOST="your-vps.example.com"
SSH_KEY="~/.ssh/id_ed25519"
SSH_PORT="22"

# Notifications (optional)
TELEGRAM_BOT_TOKEN=""      # From @BotFather
TELEGRAM_CHAT_ID=""        # Your user/group ID

# Behavior
CHECK_INTERVAL="120"       # Seconds between checks
MAX_REPAIR_ATTEMPTS="2"    # Before escalating to notification
LOG_RETENTION_DAYS="7"     # How long to keep logs
```

## Platform Support

### macOS
Fully supported. Uses launchd with automatic start on boot.

### Linux
Fully supported. Uses systemd with automatic start on boot.

### Windows (via WSL2)
Supported through WSL2. Quick setup:

```powershell
# Install WSL2 (run in PowerShell as Administrator)
wsl --install

# After restart, open WSL and run the standard install:
git clone https://github.com/gavdalf/openclaw-watchdog.git
cd openclaw-watchdog
./install.sh
```

WSL2 services persist in the background. For guaranteed uptime, enable systemd in WSL:
```bash
# In /etc/wsl.conf
[boot]
systemd=true
```

> **Note:** Native Windows (PowerShell + Task Scheduler) support may be added in a future release if there's demand.

## Manual Commands

```bash
# Run a health check manually
./bin/watchdog-check.sh

# View recent logs
tail -f logs/watchdog.log

# Test notifications
./bin/test-notify.sh "Test message"
```

## Notifications

Currently supported:
- **Telegram** — Instant alerts to your phone
- **ntfy** — Self-hosted or ntfy.sh
- **Discord** — Webhook-based (coming soon)

Future: Apprise integration for 80+ notification services.

## Architecture Decisions

**Why out-of-band?**
If the watchdog runs on the same machine as OpenClaw, a kernel panic or full system freeze takes down both. Running remotely ensures the watchdog survives to detect and report the issue.

**Why tiered recovery?**
Most OpenClaw issues are transient (port conflicts, stale locks, config drift). `openclaw doctor` fixes these automatically. LLM-based diagnosis is reserved for genuinely novel failures — keeping costs near zero for normal operation.

**Why bash?**
Minimal dependencies, runs anywhere, easy to audit. A Python rewrite with Apprise integration is on the roadmap for v2.

## License

MIT

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.
READMEOF

## Disclaimer

This software is provided "as is", without warranty of any kind. The authors are not responsible for any damage, data loss, or other issues that may arise from using this tool. **Use at your own risk.**

By installing and running this software, you acknowledge that:
- It will SSH into your servers and execute commands
- It may automatically run repair operations on your OpenClaw installation
- You are responsible for ensuring your configuration is correct
- You should test in a non-production environment first

See [LICENSE](LICENSE) for full terms.
