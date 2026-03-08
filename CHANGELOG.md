# Changelog

All notable changes to this project are documented in this file.

## [v1.1.0] - 2026-03-08

### Added

- New `bin/auth-sentinel.sh` module for Anthropic OAuth token monitoring.
- Token expiry detection for Claude CLI credentials with configurable refresh threshold and cooldown.
- Automatic OAuth refresh flow against `https://console.anthropic.com/v1/oauth/token`.
- Atomic sync of refreshed Anthropic access tokens into OpenClaw `auth-profiles.json`.
- Post-refresh OpenClaw reload actions:
  - `openclaw secrets reload`
  - `SIGUSR1` to the gateway process for in-place restart
- Post-sync Anthropic API verification with emergency retry on `401`.
- Gateway log scanning for repeated OAuth-style `401` errors to trigger emergency refresh cycles.
- Installer support for optional auth-sentinel setup and a 5-minute cron job.
- README documentation for auth-sentinel architecture, configuration, and usage examples.

### Changed

- Expanded installer-generated `.env` with `AUTH_SENTINEL_*` configuration defaults.
- Updated operational docs to cover OAuth token lifecycle management alongside health and model failover monitoring.

## [v1.0.0] - 2026-03-02

First versioned release of `openclaw-watchdog`.

### Added

- Out-of-band watchdog health monitor (`bin/watchdog-check.sh`) with tiered recovery.
- Automatic repair flow using `openclaw doctor --repair --yes` after repeated health failures.
- Config snapshot support before repair using git on the OpenClaw config directory.
- Notification support for Telegram, ntfy, and Discord.
- Interactive installer with SSH bootstrap, scheduler setup, and config generation.
- Cross-platform scheduling support:
  - macOS: launchd
  - Linux: systemd user timer
- Model health failover monitor (`bin/model-health-check.sh`) that:
  - Detects Anthropic overload conditions (including HTTP 529-style upstream failures).
  - Switches primary model to a configured fallback provider/model.
  - Detects recovery and switches back automatically.
  - Persists state to XDG-compatible storage.
  - Supports `--test` simulation mode for dry-run failover behavior.
- Installer support for model-health setup:
  - Prompt for preferred fallback model.
  - Install cron job running every 5 minutes.

### Changed

- Generalized model health check configuration to environment-driven variables with sensible defaults.
- Removed personal hardcoded values and path assumptions from runtime scripts.
- Expanded README documentation for architecture, model failover flow, and configuration.

### Security and Reliability

- Reduced risk of repeated switch churn by persisting failover state between runs.
- Added safer defaults for path resolution and state/log directory handling.
