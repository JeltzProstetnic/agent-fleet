#!/usr/bin/env bash
# setup-web-terminal.sh — Browser-based terminal access to Claude Code via ttyd + Docker nginx-proxy + HTTPS
#
# This script is designed for a VPS that already runs the Docker nginx-proxy stack
# (nginx:alpine container on ports 80/443 with certbot container for Let's Encrypt).
# It does NOT install or configure a standalone nginx — it edits the existing
# /opt/reverse-proxy/nginx.conf to add __WEB_TERMINAL_DOMAIN__ server blocks.
#
# Sets up:
#   - ttyd (v1.7.7) bound to 127.0.0.1:7681, serving a tmux "claude" session
#   - Detects Docker bridge gateway IP so the nginx container can reach ttyd on the host
#   - HTTP server block for ACME challenge + HTTPS redirect
#   - Let's Encrypt certificate via the existing certbot container
#   - HTTPS server block proxying to ttyd with full WebSocket support
#   - systemd service for ttyd (auto-restart)
#
# Usage (as root on Ubuntu 24.04 VPS):
#   bash setup-web-terminal.sh
#   TTYD_USER=myuser TTYD_PASS=mypass bash setup-web-terminal.sh   # non-interactive
#
# Prerequisites:
#   - DNS A record for __WEB_TERMINAL_DOMAIN__ → __VPS_IP__ already set
#   - Docker nginx-proxy running as container named "nginx-proxy"
#   - Certbot container with /etc/letsencrypt and /var/www/certbot volumes
#   - Run as root

set -euo pipefail

VPS_IP="${VPS_IP:-__VPS_IP__}"
DOMAIN="${DOMAIN:-__WEB_TERMINAL_DOMAIN__}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-__YOUR_EMAIL__}"
TTYD_VERSION="1.7.7"

# Validate that placeholders have been replaced
for _var in VPS_IP DOMAIN CERTBOT_EMAIL; do
  if [[ "${!_var}" == __*__ ]]; then
    echo "ERROR: $_var is still set to a placeholder. Set it via env var or edit this script."
    exit 1
  fi
done
TTYD_BIN="/usr/local/bin/ttyd"
TTYD_PORT="7681"
TMUX_SESSION="claude"
NGINX_CONF="/opt/reverse-proxy/nginx.conf"
NGINX_CONF_BAK="/opt/reverse-proxy/nginx.conf.bak"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${GREEN}═══ $* ═══${NC}"; }

# ──────────────────────────────────────────────
# Pre-flight: must run as root
# ──────────────────────────────────────────────

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# ──────────────────────────────────────────────
# Step 1: DNS check
# ──────────────────────────────────────────────
log_step "Step 1/10: DNS verification"

DNS_RESOLVED=""
if command -v dig &>/dev/null; then
    DNS_RESOLVED=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
    [[ -z "$DNS_RESOLVED" ]] && DNS_RESOLVED=$(dig +short "$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
elif command -v host &>/dev/null; then
    DNS_RESOLVED=$(host "$DOMAIN" 8.8.8.8 2>/dev/null | awk '/has address/ {print $NF}' | head -1 || true)
else
    log_warn "Neither dig nor host found — installing dnsutils..."
    apt-get install -y -qq dnsutils 2>/dev/null
    DNS_RESOLVED=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
fi

if [[ -z "$DNS_RESOLVED" ]]; then
    log_error "Could not resolve $DOMAIN — DNS lookup returned nothing."
    log_error "Make sure the A record for $DOMAIN points to $VPS_IP and has propagated."
    exit 1
fi

if [[ "$DNS_RESOLVED" != "$VPS_IP" ]]; then
    log_error "$DOMAIN resolves to $DNS_RESOLVED, expected $VPS_IP."
    log_error "Let's Encrypt will fail if DNS doesn't point to this server."
    exit 1
fi

log_info "$DOMAIN → $DNS_RESOLVED (OK)"

# ──────────────────────────────────────────────
# Step 2: Prompt for ttyd credentials
# ──────────────────────────────────────────────
log_step "Step 2/10: Credentials"

if [[ -z "${TTYD_USER:-}" ]]; then
    read -rp "ttyd username: " TTYD_USER
fi
if [[ -z "${TTYD_PASS:-}" ]]; then
    read -rsp "ttyd password: " TTYD_PASS
    echo
fi

if [[ -z "$TTYD_USER" || -z "$TTYD_PASS" ]]; then
    log_error "Username and password must not be empty."
    exit 1
fi

log_info "Credentials set for user: $TTYD_USER"

# ──────────────────────────────────────────────
# Step 3: Disable standalone nginx (previous broken install)
# ──────────────────────────────────────────────
log_step "Step 3/10: Disable standalone nginx (if installed)"

if systemctl list-units --all --type=service 2>/dev/null | grep -q 'nginx.service'; then
    log_info "Stopping and disabling standalone nginx..."
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    log_info "Standalone nginx disabled"
else
    log_info "Standalone nginx service not found — nothing to disable"
fi

# ──────────────────────────────────────────────
# Step 4: Ensure ttyd is installed + systemd service
# ──────────────────────────────────────────────
log_step "Step 4/10: ttyd v${TTYD_VERSION} + systemd service"

if [[ -f "$TTYD_BIN" ]]; then
    INSTALLED_VER=$("$TTYD_BIN" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "$INSTALLED_VER" == "$TTYD_VERSION" ]]; then
        log_info "ttyd v$TTYD_VERSION already installed at $TTYD_BIN"
    else
        log_info "ttyd $INSTALLED_VER found, upgrading to $TTYD_VERSION..."
        TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"
        log_info "Downloading ttyd from $TTYD_URL ..."
        curl -fsSL "$TTYD_URL" -o "$TTYD_BIN"
        chmod +x "$TTYD_BIN"
        log_info "ttyd installed → $TTYD_BIN"
    fi
else
    TTYD_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"
    log_info "Downloading ttyd from $TTYD_URL ..."
    curl -fsSL "$TTYD_URL" -o "$TTYD_BIN"
    chmod +x "$TTYD_BIN"
    log_info "ttyd installed → $TTYD_BIN"
fi

log_info "ttyd: $("$TTYD_BIN" --version 2>&1 | head -1)"

# Write (or overwrite) the systemd service — credentials are baked in here
SERVICE_FILE="/etc/systemd/system/ttyd.service"

log_info "Writing systemd service → $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ttyd — browser-based terminal (tmux claude session)
After=network.target

[Service]
Type=simple
ExecStart=${TTYD_BIN} \\
    --port ${TTYD_PORT} \\
    --interface 127.0.0.1 \\
    --credential ${TTYD_USER}:${TTYD_PASS} \\
    --writable \\
    --ping-interval 30 \\
    tmux new-session -A -s ${TMUX_SESSION}
User=root
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ttyd

# Give it a moment to start
sleep 2

if systemctl is-active --quiet ttyd; then
    log_info "ttyd service is running"
else
    log_warn "ttyd service may not have started cleanly — check: journalctl -u ttyd -n 30"
fi

# Verify ttyd is listening on the expected port
if ss -tlnp | grep -q ":${TTYD_PORT}"; then
    log_info "ttyd is listening on port ${TTYD_PORT} ($(ss -tlnp | grep ":${TTYD_PORT}" | head -1))"
else
    log_warn "ttyd does not appear to be listening on port ${TTYD_PORT} yet — may still be starting"
fi

# ──────────────────────────────────────────────
# Step 5: Reload tmux config
# ──────────────────────────────────────────────
log_step "Step 5/10: tmux config"

tmux source-file ~/.tmux.conf 2>/dev/null || true
log_info "tmux config reloaded (or no active server to reload)"

# ──────────────────────────────────────────────
# Step 6: Detect Docker gateway IP
# ──────────────────────────────────────────────
log_step "Step 6/10: Docker gateway IP detection"

GATEWAY_IP=""
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nginx-proxy$'; then
    GATEWAY_IP=$(docker exec nginx-proxy ip route 2>/dev/null | awk '/default/ {print $3}' | head -1 || true)
    if [[ -n "$GATEWAY_IP" ]]; then
        log_info "Docker gateway IP (from nginx-proxy container): $GATEWAY_IP"
    else
        log_warn "Could not extract gateway IP from nginx-proxy container — falling back to 172.17.0.1"
        GATEWAY_IP="172.17.0.1"
    fi
else
    log_warn "nginx-proxy container not found or not running — using fallback gateway IP 172.17.0.1"
    GATEWAY_IP="172.17.0.1"
fi

log_info "Using gateway IP: $GATEWAY_IP"

# Verify connectivity: check if the gateway IP port 7681 is reachable from inside the container
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nginx-proxy$'; then
    log_info "Testing connectivity from nginx-proxy container to ${GATEWAY_IP}:${TTYD_PORT}..."
    if docker exec nginx-proxy sh -c "wget -qO- --timeout=3 http://${GATEWAY_IP}:${TTYD_PORT}/ >/dev/null 2>&1"; then
        log_info "Connectivity check passed: nginx-proxy → ${GATEWAY_IP}:${TTYD_PORT}"
    else
        # wget may fail with non-zero on HTTP errors but still reach the port; try nc/timeout approach
        if docker exec nginx-proxy sh -c "timeout 3 sh -c '</dev/tcp/${GATEWAY_IP}/${TTYD_PORT}' 2>/dev/null"; then
            log_info "Connectivity check passed (TCP): nginx-proxy → ${GATEWAY_IP}:${TTYD_PORT}"
        else
            log_warn "Could not verify connectivity from nginx-proxy to ${GATEWAY_IP}:${TTYD_PORT}"
            log_warn "ttyd may not yet be listening — check after this script completes"
        fi
    fi
fi

# ──────────────────────────────────────────────
# Step 7: Add HTTP server block to nginx.conf (ACME challenge)
# ──────────────────────────────────────────────
log_step "Step 7/10: HTTP server block in $NGINX_CONF"

if [[ ! -f "$NGINX_CONF" ]]; then
    log_error "$NGINX_CONF not found — is the Docker nginx-proxy stack deployed?"
    exit 1
fi

if grep -q "server_name ${DOMAIN}" "$NGINX_CONF" 2>/dev/null; then
    log_info "server_name ${DOMAIN} already exists in nginx.conf — skipping HTTP block insertion"
else
    log_info "Backing up nginx.conf → $NGINX_CONF_BAK"
    cp "$NGINX_CONF" "$NGINX_CONF_BAK"

    log_info "Inserting HTTP server block for $DOMAIN..."
    python3 - <<PYEOF
import sys

nginx_conf = """${NGINX_CONF}"""
with open(nginx_conf, 'r') as f:
    content = f.read()

http_block = """
    server {
        listen 80;
        server_name ${DOMAIN};
        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }
        location / {
            return 301 https://\$host\$request_uri;
        }
    }
"""

# Find the last closing brace in the file (closes the http {} block)
last_brace_pos = content.rfind('}')
if last_brace_pos == -1:
    print("ERROR: Could not find closing brace in nginx.conf", file=sys.stderr)
    sys.exit(1)

new_content = content[:last_brace_pos] + http_block + content[last_brace_pos:]

with open(nginx_conf, 'w') as f:
    f.write(new_content)

print("HTTP server block inserted successfully")
PYEOF

    log_info "Testing nginx config..."
    docker exec nginx-proxy nginx -t
    log_info "Reloading nginx-proxy..."
    docker exec nginx-proxy nginx -s reload
    log_info "nginx-proxy reloaded with HTTP block for $DOMAIN"
fi

# ──────────────────────────────────────────────
# Step 8: Get SSL certificate via certbot container
# ──────────────────────────────────────────────
log_step "Step 8/10: Let's Encrypt certificate"

CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

if [[ -f "$CERT_PATH" ]]; then
    log_info "Certificate already exists for $DOMAIN at $CERT_PATH — skipping issuance"
else
    log_info "Requesting certificate for $DOMAIN via certbot container..."
    docker run --rm \
        -v /etc/letsencrypt:/etc/letsencrypt \
        -v /var/www/certbot:/var/www/certbot \
        certbot/certbot certonly \
            --webroot \
            -w /var/www/certbot \
            -d "$DOMAIN" \
            --non-interactive \
            --agree-tos \
            -m "$CERTBOT_EMAIL"
fi

if [[ -f "$CERT_PATH" ]]; then
    log_info "Certificate verified at $CERT_PATH"
else
    log_error "Certificate not found at $CERT_PATH after certbot run — aborting"
    exit 1
fi

# ──────────────────────────────────────────────
# Step 9: Add HTTPS server block to nginx.conf
# ──────────────────────────────────────────────
log_step "Step 9/10: HTTPS server block in $NGINX_CONF"

if grep -q "listen 443" "$NGINX_CONF" 2>/dev/null && grep -q "server_name ${DOMAIN}" "$NGINX_CONF" 2>/dev/null; then
    log_info "HTTPS block for $DOMAIN already exists in nginx.conf — skipping"
else
    log_info "Inserting HTTPS server block for $DOMAIN (gateway: $GATEWAY_IP)..."
    python3 - <<PYEOF
import sys

nginx_conf = """${NGINX_CONF}"""
domain = """${DOMAIN}"""
gateway_ip = """${GATEWAY_IP}"""
ttyd_port = """${TTYD_PORT}"""

with open(nginx_conf, 'r') as f:
    content = f.read()

# Double-check: skip if HTTPS block for this domain already exists
if 'listen 443' in content and domain in content:
    # Check if the 443 block is specifically for our domain
    import re
    pattern = r'listen 443.*?' + re.escape(domain)
    if re.search(pattern, content, re.DOTALL):
        print("HTTPS block already present — skipping")
        sys.exit(0)

https_block = f"""
    server {{
        listen 443 ssl;
        http2 on;
        server_name {domain};
        ssl_certificate /etc/letsencrypt/live/{domain}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/{domain}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA384;
        ssl_prefer_server_ciphers off;
        add_header Strict-Transport-Security "max-age=63072000" always;
        location / {{
            proxy_pass http://{gateway_ip}:{ttyd_port};
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 86400;
            proxy_send_timeout 86400;
            proxy_buffering off;
        }}
    }}
"""

# Find the last closing brace in the file (closes the http {} block)
last_brace_pos = content.rfind('}')
if last_brace_pos == -1:
    print("ERROR: Could not find closing brace in nginx.conf", file=sys.stderr)
    sys.exit(1)

new_content = content[:last_brace_pos] + https_block + content[last_brace_pos:]

with open(nginx_conf, 'w') as f:
    f.write(new_content)

print("HTTPS server block inserted successfully")
PYEOF

    log_info "Testing nginx config..."
    docker exec nginx-proxy nginx -t
    log_info "Reloading nginx-proxy..."
    docker exec nginx-proxy nginx -s reload
    log_info "nginx-proxy reloaded with HTTPS block for $DOMAIN"
fi

# ──────────────────────────────────────────────
# Step 10: Final verification
# ──────────────────────────────────────────────
log_step "Step 10/10: Final verification"

# ttyd service
if systemctl is-active --quiet ttyd; then
    log_info "ttyd service: running"
else
    log_warn "ttyd service: NOT running — check: journalctl -u ttyd -n 50"
fi

# nginx-proxy container
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nginx-proxy$'; then
    log_info "nginx-proxy container: running"
else
    log_warn "nginx-proxy container: NOT running"
fi

# Certificate
if [[ -f "$CERT_PATH" ]]; then
    log_info "SSL certificate: present ($CERT_PATH)"
else
    log_warn "SSL certificate: NOT found at $CERT_PATH"
fi

# HTTP connectivity test (may need --resolve if local DNS is stale)
log_info "Testing HTTPS connectivity..."
HTTP_STATUS=$(curl -sSo /dev/null -w "%{http_code}" \
    --resolve "${DOMAIN}:443:127.0.0.1" \
    --max-time 10 \
    "https://${DOMAIN}/" 2>/dev/null || true)

if [[ "$HTTP_STATUS" =~ ^(200|101|302|401)$ ]]; then
    log_info "HTTPS test: HTTP $HTTP_STATUS (OK)"
elif [[ -n "$HTTP_STATUS" ]]; then
    log_warn "HTTPS test returned HTTP $HTTP_STATUS — check nginx logs if unexpected"
else
    log_warn "HTTPS test: no response — nginx-proxy or ttyd may need a moment to settle"
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo -e "${GREEN} Web terminal setup complete!${NC}"
echo "═══════════════════════════════════════════════"
echo ""
echo "  URL:       https://${DOMAIN}"
echo "  Username:  ${TTYD_USER}"
echo "  Password:  (as entered)"
echo ""
echo "  Gateway:   nginx-proxy → host at ${GATEWAY_IP}:${TTYD_PORT}"
echo ""
echo "  Services:"
echo "    ttyd         — systemctl status ttyd"
echo "    nginx-proxy  — docker ps / docker logs nginx-proxy"
echo "    certbot      — docker run certbot/certbot renew"
echo ""
echo "  tmux session name: ${TMUX_SESSION}"
echo "  ttyd starts:       tmux new-session -A -s ${TMUX_SESSION}"
echo "  (Attaches if the session exists, creates if not)"
echo ""
echo "  To start Claude Code in the session:"
echo "    ssh into VPS, then: tmux attach -t ${TMUX_SESSION}"
echo "    cd ~/agent-fleet && mclaude"
echo ""
echo "  Logs:"
echo "    journalctl -u ttyd -f"
echo "    docker logs -f nginx-proxy"
echo "    /opt/reverse-proxy/nginx.conf  (edited by this script)"
echo "    /opt/reverse-proxy/nginx.conf.bak  (backup before edits)"
echo ""
echo "  If ttyd credentials change, re-run this script."
echo "  The systemd service will be overwritten with new credentials."
echo ""
