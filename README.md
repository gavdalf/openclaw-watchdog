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

┌─────────────────────┐   OAuth refresh/API   ┌─────────────────────┐
│ AUTH SENTINEL       │ ───────────────────▶  │ Anthropic API       │
│ (every 5 min, cron) │                       │ + OAuth endpoint    │
│ - Checks expiry     │                       └─────────────────────┘
│ - Refreshes token   │
│ - Syncs OpenClaw    │
│ - Verifies token    │
└─────────────────────┘
```

## Recovery Tiers

| Tier | Action | Cost |
|------|--------|------|
| 1 | `openclaw health --json` | Free |
| 2 | `openclaw doctor --repair --yes` | Free |
| 3 | Notification (Telegram/ntfy/Discord) | Free |
| 4 | Model provider failover (Anthropic ⇄ OpenRouter) | Free |
| 5 | OAuth token refresh + OpenClaw auth sync | Free |

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

## Auth Sentinel

`bin/auth-sentinel.sh` monitors Anthropic OAuth credentials used by Claude CLI and keeps OpenClaw in sync. On each run it can:

1. Read `~/.claude/.credentials.json` and evaluate token expiry.
2. Refresh the token when expired or inside the configured threshold.
3. Write the refreshed access token into OpenClaw `auth-profiles.json`.
4. Run `openclaw secrets reload` and send `SIGUSR1` to the gateway process.
5. Verify the synced token with a lightweight `POST /v1/messages` probe.
6. Trigger an emergency refresh cycle when repeated OAuth-style `401` errors appear in the gateway log.

### Auth Flow

```text
~/.claude/.credentials.json
        │
        │ expiry check / refresh_token
        ▼
Anthropic OAuth token endpoint
        │
        │ new access_token
        ▼
auth-sentinel.sh
        │
        ├── writes ~/.openclaw/.../auth-profiles.json
        ├── runs openclaw secrets reload
        ├── sends SIGUSR1 to openclaw gateway
        └── verifies token with POST /v1/messages
```

### Test Mode

```bash
WATCHDOG_CONFIG=.env ./bin/auth-sentinel.sh --test
```

`--test` simulates token expiry, logs the refresh/sync/reload flow, and avoids modifying credentials, auth profiles, or state.

## Requirements

- Watchdog machine: macOS, Linux, or Windows (via WSL2)
- SSH access to your OpenClaw host (key-based auth recommended)
- OpenClaw CLI installed on the target host
- `python3`, `jq`, `curl`, `ssh`, `git`
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
7. Optionally installs a cron job every 5 minutes for Anthropic OAuth token monitoring and sync.

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

### Auth Sentinel

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENABLE_AUTH_SENTINEL` | `false` | Enables installer-managed auth monitoring cron setup. |
| `AUTH_SENTINEL_CLAUDE_CREDS` | `~/.claude/.credentials.json` | Claude CLI credentials file containing `claudeAiOauth`. |
| `AUTH_SENTINEL_OPENCLAW_AUTH` | `~/.openclaw/agents/main/agent/auth-profiles.json` | OpenClaw auth profiles file that receives the refreshed token. |
| `AUTH_SENTINEL_GATEWAY_LOG` | `<install>/logs/<date>.log` | Log scanned for repeated OAuth `401` patterns. |
| `AUTH_SENTINEL_REFRESH_THRESHOLD_MINS` | `90` | Refresh when expiry is within this many minutes. |
| `AUTH_SENTINEL_COOLDOWN_SECS` | `300` | Minimum time between active refresh/sync actions. |
| `AUTH_SENTINEL_OAUTH_CLIENT_ID` | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` | Anthropic OAuth client ID used during refresh. |
| `AUTH_SENTINEL_VERIFY_MODEL` | `claude-haiku-4-5` | Model used for the post-sync verification probe. |
| `AUTH_SENTINEL_STATE_DIR` | `${XDG_DATA_HOME:-$HOME/.config}/openclaw-watchdog` | State and lock directory. |
| `AUTH_SENTINEL_STATE_FILE` | `${AUTH_SENTINEL_STATE_DIR}/auth-sentinel-state.json` | Exact state file override. |
| `AUTH_SENTINEL_LOG_DIR` | `<install>/logs` | Log directory override. |
| `AUTH_SENTINEL_LOG_FILE` | `${AUTH_SENTINEL_LOG_DIR}/auth-sentinel.log` | Exact log file override. |
| `OPENCLAW_CMD` | `openclaw` | CLI used for `secrets reload`. |

State location defaults to `${XDG_DATA_HOME:-$HOME/.config}/openclaw-watchdog/auth-sentinel-state.json`.

## Manual Commands

```bash
./bin/watchdog-check.sh
WATCHDOG_CONFIG=.env ./bin/model-health-check.sh
WATCHDOG_CONFIG=.env ./bin/model-health-check.sh --test
WATCHDOG_CONFIG=.env ./bin/auth-sentinel.sh
WATCHDOG_CONFIG=.env ./bin/auth-sentinel.sh --test
./bin/test-notify.sh "Test message"
```

Auth sentinel examples:

```bash
# Run a real expiry / 401 check
WATCHDOG_CONFIG=.env ./bin/auth-sentinel.sh

# Dry-run the full refresh path
WATCHDOG_CONFIG=.env ./bin/auth-sentinel.sh --test

# Override paths for a custom OpenClaw agent layout
AUTH_SENTINEL_CLAUDE_CREDS="$HOME/.claude/.credentials.json" \
AUTH_SENTINEL_OPENCLAW_AUTH="$HOME/.openclaw/agents/main/agent/auth-profiles.json" \
WATCHDOG_CONFIG=.env ./bin/auth-sentinel.sh
```

## Platform Support

### macOS

Supported via launchd for watchdog checks + cron for model health/auth-sentinel checks.

### Linux

Supported via systemd user timer for watchdog checks + cron for model health/auth-sentinel checks.

### Windows (WSL2)

Supported through WSL2 with the same install process.

## Notifications

- Telegram
- ntfy
- Discord webhook

## Architecture Decisions

Why out-of-band: if the gateway host fails, watchdog checks and notifications still run.

Why tiered recovery: most issues are transient and solvable by `openclaw doctor`; failover adds model-level resilience during provider incidents.

Why auth-sentinel: Anthropic OAuth tokens are time-bound; automatic refresh + sync avoids gateway drift when Claude CLI rotates credentials.

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
- Anthropic OAuth tokens may be refreshed and synced automatically into OpenClaw auth profiles.
- You are responsible for validating your configuration and testing safely.

See [LICENSE](LICENSE) for full terms.
