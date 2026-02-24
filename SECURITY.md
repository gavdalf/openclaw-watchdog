# Security Model

This tool has SSH access to your VPS and can execute commands. Security is not optional.

## SSH Key Security

### Dedicated Key Pair
**Never use your personal SSH key.** Generate a dedicated key just for the watchdog:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/watchdog-key -N "" -C "openclaw-watchdog"
```

Add to your VPS `~/.ssh/authorized_keys` with restrictions:

```
command="/usr/local/bin/openclaw-watchdog-remote",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... openclaw-watchdog
```

This limits the key to only running the watchdog remote script.

### Non-Root User (Recommended)
Create a dedicated user on your VPS:

```bash
# On VPS
sudo useradd -m -s /bin/bash openclaw-watchdog
sudo usermod -aG openclaw openclaw-watchdog  # if openclaw group exists

# Grant specific sudo access
echo "openclaw-watchdog ALL=(ALL) NOPASSWD: /usr/bin/systemctl --user restart openclaw-gateway" | sudo tee /etc/sudoers.d/openclaw-watchdog
```

## Secrets Management

### File Permissions
Your `.env` file contains secrets. Lock it down:

```bash
chmod 600 ~/.config/openclaw-watchdog/watchdog.env
```

The install script does this automatically.

### What NOT to Do
- ❌ Never commit `.env` to git
- ❌ Never share your `.env` file
- ❌ Never put secrets in the doctor prompt
- ❌ Never use the same SSH key for other purposes

### Key Rotation
If you suspect compromise:

1. Generate new SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/watchdog-key-new`
2. Add new key to VPS authorized_keys
3. Update `OPENCLAW_SSH_KEY` in `.env`
4. Test: `openclaw-watchdog check`
5. Remove old key from VPS
6. Regenerate notification tokens (Telegram bot, Discord webhook, etc.)

## AI Repair Safety (Tier 3)

Tier 3 uses Claude Code to diagnose and fix issues. This is powerful but risky.

### Safeguards

1. **Disabled by Default**: Set `ENABLE_AI_REPAIR=false` until you understand the risks
2. **Command Whitelist**: The doctor prompt explicitly forbids destructive commands
3. **Audit Logging**: Every AI suggestion and execution is logged
4. **Dry Run Mode**: Set `AI_REPAIR_DRY_RUN=true` to see what would be executed without running it

### What Claude Code CAN Do
- Run `openclaw doctor`
- Restart services via systemctl
- Read logs and config files
- Make config changes (with backup)

### What Claude Code CANNOT Do (blocked in doctor prompt)
- `rm -rf` anything
- `dd` commands
- Modify SSH keys or authorized_keys
- Access other services/containers
- Make network changes
- Install packages without approval

### Approval Mode (Coming in v1.1)
Instead of auto-executing, get notified of the suggested fix and approve/reject.

## Network Security

### Recommended: Private Network
Use Tailscale, WireGuard, or similar to keep SSH off the public internet:

```bash
# In .env
OPENCLAW_HOST=100.x.x.x  # Tailscale IP, not public IP
```

### If Using Public SSH
- Disable password authentication
- Use fail2ban
- Consider port knocking
- Restrict to specific IPs if possible

## Audit Trail

Every action is logged to `~/.local/share/openclaw-watchdog/watchdog.log`:

```
[2026-02-24 12:00:00] CHECK: Health check started
[2026-02-24 12:00:01] CHECK: Gateway healthy ✓
[2026-02-24 12:02:00] CHECK: Health check failed (1/3)
[2026-02-24 12:04:00] CHECK: Health check failed (2/3)
[2026-02-24 12:06:00] CHECK: Health check failed (3/3) - THRESHOLD REACHED
[2026-02-24 12:06:01] REPAIR: Running openclaw doctor --repair --yes
[2026-02-24 12:06:15] REPAIR: Doctor completed successfully
[2026-02-24 12:06:16] CHECK: Gateway healthy ✓
[2026-02-24 12:06:17] NOTIFY: Sent recovery notification to Telegram
```

Logs are rotated automatically. Keep them for at least 30 days.

## Threat Model

| Threat | Mitigation |
|--------|------------|
| SSH key stolen | Dedicated key with command restrictions, rotate immediately if suspected |
| .env file leaked | chmod 600, never commit to git, rotate all tokens |
| AI suggests malicious command | Command whitelist, audit logging, dry-run mode, approval mode |
| VPS compromised | Watchdog can't prevent this, but can detect (health checks fail) |
| Monitor machine compromised | Attacker gets SSH access to VPS — use command restrictions to limit blast radius |

## Reporting Security Issues

If you find a security vulnerability, please email [security@example.com] instead of opening a public issue.

We take security seriously and will respond within 48 hours.
