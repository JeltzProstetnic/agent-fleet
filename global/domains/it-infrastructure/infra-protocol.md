# IT Infrastructure Protocol

**Applies to:** agent-fleet (VPS/bootstrap), any infra work

## Scope

Home and cloud infrastructure: servers, networking, Docker services, DNS, SSL, smart home, deployment pipelines.

## Machines & Services

**Always check current state in:** `~/agent-fleet/cross-project/infrastructure-strategy.md`

Key systems:
- **VPS** (__VPS_IP__): Ubuntu 24.04, Docker, nginx-proxy, ttyd web terminal, Claude Code
- **Home Server**: Local server for Docker, Home Assistant, etc. (customize per setup)
- **__WSL_MACHINE__**: Primary dev, WSL2/Ubuntu

## Operational Rules

### Before changing infrastructure:
1. Read `~/agent-fleet/cross-project/infrastructure-strategy.md` for current state
2. Check which services depend on what you're changing
3. For VPS: verify SSH access works before making changes
4. For Docker: `docker ps` before touching containers

### DNS & SSL
- DNS managed via Hostinger panel (__YOUR_DOMAIN__, __YOUR_DOMAIN__)
- SSL certs via Let's Encrypt + certbot
- Always set up HTTP first (for ACME challenge), then add HTTPS
- Track cert expiry dates in infrastructure-strategy.md

### Docker conventions
- Use docker-compose where possible
- nginx-proxy pattern: reverse proxy in front of services
- Bind mounts preferred over named volumes (easier backup)
- Always document port mappings

### Service changes
- After adding/removing a service: update infrastructure-strategy.md
- After changing access methods (ports, URLs, auth): update infrastructure-strategy.md
- After deploying to a new machine: update registry.md + infrastructure-strategy.md

### Smart Home (Home Assistant)
- Config lives on home server, exposed via SSH tunnel to VPS
- Backup HA config before any migration
- Test automations after any infrastructure change

## Coordination

Infrastructure touches multiple projects. Use `~/agent-fleet/cross-project/inbox.md` to notify other projects of changes. See `infrastructure-strategy.md` § Coordination Rules for the full protocol.
