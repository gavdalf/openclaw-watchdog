# openclaw-watchdog

Self-healing monitoring for OpenClaw gateways. Runs out-of-band, detects failures, and auto-repairs.

## How It Works

The watchdog runs on a separate machine from your OpenClaw instance. This out-of-band design means if your gateway host is unhealthy, monitoring and alerting are still alive.

```text
┌─────────────────────┐         SSH          ┌─────────────────────┐
│   WATCHDOG HOST     │ ──────────────────▶  │   OPENCLAW HOST     │
│   (Mac/Linux/WSL)   │                      │   (VPS/Server)      │
│                     │   openclaw health    │                     │
│   Runs every 2 min  │ ◀────────────────── │   Gateway runtime   │
│   Detects failures  │        JSON          │                     │
│   Triggers repairs  │                      │                     │
└─────────────────────┘                      └─────────────────────┘

┌─────────────────────┐      HTTPS probes     ┌─────────────────────┐
│ MODEL HEALTH CHECK  │ ───────────────────▶  │ OpenRouter API      │
│ (every 5 min, cron) │                       │ (Anthropic status)  │
│ - Detects HTTP 529  │                       └─────────────────────┘
│ - Switches model    │
│ - Switches back     │
└─────────────────────┘
```

## Recovery Tiers

| Tier | Action | Cost |
|------|--------|------|
| 1 | `openclaw health --json` | Free |
| 2 | `openclaw doctor --repair --yes` | Free |
| 3 | Notification (Telegram/ntfy/Discord) | Free |
| 4 | Model provider failover (Anthropic ⇄ OpenRouter) | Free |

## Model Health Check

`bin/model-health-check.sh` detects Anthropic overload events (for example HTTP `529`) using an API probe, then:

1. Switches gateway primary model to your configured fallback model.
2. Sends a notification.
3. Keeps monitoring.
4. Switches back to the primary Anthropic model after recovery.

A state file prevents repeated flip-flopping and tracks prior switch status.

### Test Mode

```bash
WATCHDOG_CONFIG=.env ./bin/model-health-check.sh --test
```

`--test` simulates an Anthropic `529` event, logs actions, and shows what would happen without applying config changes.

## Requirements

- Watchdog machine: macOS, Linux, or Windows (via WSL2)
- SSH access to your OpenClaw host (key-based auth recommended)
- OpenClaw CLI installed on the target host
- `jq`, `curl`, `ssh`, `git`
- Optional notifications (Telegram/ntfy/Discord)

## Quick Install

```bash
git clone https://github.com/openclaw/openclaw-watchdog.git
cd openclaw-watchdog
./install.sh
```

Installer actions:

1. Prompts for OpenClaw SSH connection.
2. Configures health/repair monitoring.
3. Configures notifications.
4. Prompts for preferred fallback model.
5. Installs watchdog scheduler (launchd on macOS, systemd on Linux).
6. Installs a cron job every 5 minutes for model health failover checks.

## Configuration

All settings live in `.env`.

### Core Watchdog

```bash
SSH_USER="root"
SSH_HOST="your-vps.example.com"
SSH_KEY="~/.ssh/id_ed25519"
SSH_PORT="22"

TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
NTFY_TOPIC=""
NTFY_SERVER="https://ntfy.sh"
DISCORD_WEBHOOK_URL=""

MAX_REPAIR_ATTEMPTS="2"
ENABLE_CONFIG_BACKUP="true"
OPENCLAW_CONFIG_DIR="~/.openclaw"
```

### Model Health Check

```bash
MODEL_HEALTH_PRIMARY_MODEL="anthropic/claude-sonnet-4-6"
MODEL_HEALTH_FALLBACK_MODEL="openrouter/anthropic/claude-sonnet-4-6"
MODEL_HEALTH_PROBE_MODEL="anthropic/claude-haiku-4-5"
MODEL_HEALTH_API_BASE="https://openrouter.ai/api/v1"
MODEL_HEALTH_API_KEY=""                 # optional override
OPENROUTER_API_KEY=""                   # used if MODEL_HEALTH_API_KEY is empty
MODEL_HEALTH_OVERLOAD_CODES="529 503 502 429"
MODEL_HEALTH_STATE_DIR=""               # default: ${XDG_DATA_HOME:-$HOME/.config}/openclaw-watchdog
MODEL_HEALTH_STATE_FILE=""              # optional exact state file path
MODEL_HEALTH_LOG_DIR=""                 # default: <install>/logs
MODEL_HEALTH_LOG_FILE=""                # optional exact log file path
OPENCLAW_CMD="openclaw"
```

State location defaults to `${XDG_DATA_HOME:-$HOME/.config}/openclaw-watchdog/model-health-state.json`.

## Manual Commands

```bash
./bin/watchdog-check.sh
WATCHDOG_CONFIG=.env ./bin/model-health-check.sh
WATCHDOG_CONFIG=.env ./bin/model-health-check.sh --test
./bin/test-notify.sh "Test message"
```

## Platform Support

### macOS

Supported via launchd for watchdog checks + cron for model health checks.

### Linux

Supported via systemd user timer for watchdog checks + cron for model health checks.

### Windows (WSL2)

Supported through WSL2 with the same install process.

## Notifications

- Telegram
- ntfy
- Discord webhook

## Architecture Decisions

Why out-of-band: if the gateway host fails, watchdog checks and notifications still run.

Why tiered recovery: most issues are transient and solvable by `openclaw doctor`; failover adds model-level resilience during provider incidents.

Why shell scripts: minimal dependencies, transparent behavior, easy auditing.

## License

MIT

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This software is provided "as is", without warranty of any kind. Use at your own risk.

By installing and running this software, you acknowledge that:

- It will SSH into your servers and execute commands.
- It may automatically run repair operations on your OpenClaw installation.
- Model routing may be patched automatically during provider incidents.
- You are responsible for validating your configuration and testing safely.

See [LICENSE](LICENSE) for full terms.
