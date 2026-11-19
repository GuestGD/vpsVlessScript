#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Interactive installer for Xray-core (VLESS + TLS + XTLS-Vision) with an
# HTTPS fallback site, Let's Encrypt auto-renewal, TCP BBR, UFW, and vlessLink.
# Supported OS: Ubuntu 22.04/24.04+, Debian 11/12+
# ==============================================================================

# Optional: pin a specific Xray-core version (e.g., "v26.10.31").
# Leave empty to always install the latest release.
XRAY_VERSION=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

on_error() {
    local line="$1"
    local cmd="$2"
    echo ""
    echo -e "${RED}[FATAL]${NC} Failed on line ${line} while running: ${cmd}"
    echo -e "${YELLOW}Check the output above. If certbot failed, verify your domain's A record points to this server and port 80 is reachable.${NC}"
    exit 1
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# --- Root & OS check ---
[[ $EUID -eq 0 ]] || error "Please run this script as root (sudo bash $0)."
command -v apt-get >/dev/null 2>&1 || error "Only Debian and Ubuntu (apt-get) are supported."

clear || true
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Xray VLESS (TLS + XTLS-Vision) + Fallback + BBR Setup    ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# --- Step 1. Interactive input ---
while true; do
    read -rp "1. Enter your domain name (e.g. vpn.example.com): " DOMAIN
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN%%/*}"
    if [[ -n "$DOMAIN" && "$DOMAIN" == *.* && "$DOMAIN" != *" "* ]]; then
        break
    fi
    warn "Invalid domain name. Please try again."
done

read -rp "2. Email for Let's Encrypt notifications (press Enter to skip): " CERT_EMAIL

while true; do
    read -rp "3. Enter client UUID (press Enter to auto-generate): " USER_UUID
    if [[ -z "$USER_UUID" ]]; then
        USER_UUID=$(cat /proc/sys/kernel/random/uuid)
        info "Generated new UUID: $USER_UUID"
        break
    elif [[ "$USER_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        break
    else
        warn "Invalid UUID format (expected xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
    fi
done

read -rp "4. Profile name for VPN client [default: $DOMAIN]: " PROFILE_NAME
PROFILE_NAME="${PROFILE_NAME:-$DOMAIN}"

read -rp "5. SSH port on this server [default: 22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    error "Invalid SSH port: $SSH_PORT"
fi

echo ""
echo "6. Fallback website (served when visiting https://$DOMAIN in a browser):"
echo "   1) Built-in lightweight HTML page (reliable, no external dependencies)"
echo "   2) Clone a static site from a public Git repository (HTML/JS/CSS)"
read -rp "Choose an option [1/2, default: 1]: " SITE_CHOICE
SITE_CHOICE="${SITE_CHOICE:-1}"

GIT_REPO_URL=""
if [[ "$SITE_CHOICE" == "2" ]]; then
    read -rp "   Enter HTTPS Git repository URL (e.g. https://github.com/user/site.git): " GIT_REPO_URL
    [[ -n "$GIT_REPO_URL" ]] || error "Repository URL cannot be empty."
fi

echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Installation cancelled."; exit 0; }

# --- Step 2. Install dependencies ---
info "Updating package lists and installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl openssl unzip python3 qrencode ufw git certbot

# --- Step 3. Strict port & DNS checks ---
info "Checking if ports 80 and 443 are free..."
if ss -tlnp | grep -qE ':(80|443)\s'; then
    echo -e "${RED}Ports 80 or 443 are already in use by another process:${NC}"
    ss -tlnp | grep -E ':(80|443)\s' || true
    error "Stop the conflicting service (e.g. nginx, apache2, caddy) and run this script again."
fi
ok "Ports 80 and 443 are free."

info "Checking DNS A record for $DOMAIN..."
SERVER_IP=$(
    curl -4 -s --max-time 8 https://api.ipify.org \
    || curl -4 -s --max-time 8 https://ifconfig.me \
    || curl -4 -s --max-time 8 https://icanhazip.com \
    || true
)
SERVER_IP="${SERVER_IP//$'\n'/}"
DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1 || true)

if [[ -z "$SERVER_IP" ]]; then
    warn "Could not detect this server's public IPv4 address. Skipping automatic DNS match."
elif [[ -z "$DOMAIN_IP" ]]; then
    warn "Could not resolve an IPv4 A record for $DOMAIN."
    read -rp "Continue anyway? Certbot may fail to issue a certificate [y/N]: " DNS_CONT
    [[ "$DNS_CONT" =~ ^[Yy]$ ]] || exit 1
elif [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    warn "Domain A record ($DOMAIN_IP) does not match this server's IP ($SERVER_IP)!"
    warn "Make sure DNS is configured and Cloudflare proxy (orange cloud) is disabled."
    read -rp "Continue anyway? [y/N]: " DNS_CONT
    [[ "$DNS_CONT" =~ ^[Yy]$ ]] || exit 1
else
    ok "DNS looks good: $DOMAIN -> $DOMAIN_IP"
fi

# --- Step 4. Enable TCP BBR ---
info "Enabling TCP BBR + fq..."
cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null
ok "TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"

# --- Step 5. Configure UFW firewall ---
info "Configuring UFW (allowing ports $SSH_PORT, 80, 443)..."
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
systemctl enable ufw >/dev/null 2>&1 || true
ok "UFW enabled and configured."

# --- Step 6. Obtain Let's Encrypt SSL certificate ---
info "Obtaining SSL certificate for $DOMAIN..."
CERTBOT_ARGS=(certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos)
if [[ -n "$CERT_EMAIL" ]]; then
    CERTBOT_ARGS+=(-m "$CERT_EMAIL")
else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"
ok "SSL certificate issued successfully."

# --- Step 7. Install Xray-core ---
info "Installing Xray-core..."
XRAY_INSTALL_ARGS=(install)
if [[ -n "$XRAY_VERSION" ]]; then
    XRAY_INSTALL_ARGS+=(--version "$XRAY_VERSION")
fi
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ "${XRAY_INSTALL_ARGS[@]}"

# Detect Xray service user (dedicated 'xray' since 2026-10-18, 'nobody' on older releases)
if id -u xray >/dev/null 2>&1; then
    XRAY_USER="xray"
else
    XRAY_USER="nobody"
fi
XRAY_GROUP="$(id -gn "$XRAY_USER")"
info "Xray service user: ${XRAY_USER}:${XRAY_GROUP}"

mkdir -p /usr/local/etc/xray/certs /var/log/xray
chown root:"$XRAY_GROUP" /usr/local/etc/xray /usr/local/etc/xray/certs
chmod 0750 /usr/local/etc/xray /usr/local/etc/xray/certs
chown -R "${XRAY_USER}:${XRAY_GROUP}" /var/log/xray
chmod 0700 /var/log/xray

# --- Step 8. SSL auto-renewal deploy hook ---
info "Configuring Certbot deploy hook for Xray..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/xray-certs.sh << EOF
#!/usr/bin/env bash
set -e
DOMAIN="${DOMAIN}"
CERT_DIR="/usr/local/etc/xray/certs"
XRAY_GROUP="${XRAY_GROUP}"

mkdir -p "\$CERT_DIR"
cp -L "/etc/letsencrypt/live/\${DOMAIN}/fullchain.pem" "\${CERT_DIR}/fullchain.pem"
cp -L "/etc/letsencrypt/live/\${DOMAIN}/privkey.pem" "\${CERT_DIR}/privkey.pem"
chown root:"\$XRAY_GROUP" "\$CERT_DIR"
chmod 0750 "\$CERT_DIR"
chown root:"\$XRAY_GROUP" "\${CERT_DIR}/fullchain.pem" "\${CERT_DIR}/privkey.pem"
chmod 0640 "\${CERT_DIR}/fullchain.pem" "\${CERT_DIR}/privkey.pem"
systemctl restart xray || true
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/xray-certs.sh

# Run hook immediately to copy initial certificates
/etc/letsencrypt/renewal-hooks/deploy/xray-certs.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

# --- Step 9. Configure Xray ---
info "Writing /usr/local/etc/xray/config.json..."
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${USER_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "127.0.0.1:8080",
            "xver": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/usr/local/etc/xray/certs/fullchain.pem",
              "keyFile": "/usr/local/etc/xray/certs/privkey.pem"
            }
          ],
          "alpn": [
            "http/1.1"
          ]
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "tcpKeepAliveIdle": 300
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

printf '%s\n' "$PROFILE_NAME" > /usr/local/etc/xray/.profile_name
chown root:"$XRAY_GROUP" /usr/local/etc/xray/config.json /usr/local/etc/xray/.profile_name
chmod 0640 /usr/local/etc/xray/config.json /usr/local/etc/xray/.profile_name

# Validate config and certificate permissions as the actual Xray service user
runuser -u "$XRAY_USER" -- /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json
systemctl enable xray
systemctl restart xray
ok "Xray started successfully."

# --- Step 10. Isolated fallback website on 127.0.0.1:8080 ---
info "Setting up fallback static site on 127.0.0.1:8080..."
SITE_ROOT="/var/www/fallback-site"
WEB_DIR="$SITE_ROOT"
rm -rf "$SITE_ROOT"
mkdir -p "$SITE_ROOT"

if [[ "$SITE_CHOICE" == "2" ]]; then
    if git clone --depth=1 "$GIT_REPO_URL" "$SITE_ROOT"; then
        if [[ -f "$SITE_ROOT/index.html" ]]; then
            WEB_DIR="$SITE_ROOT"
        elif [[ -f "$SITE_ROOT/dist/index.html" ]]; then
            WEB_DIR="$SITE_ROOT/dist"
        elif [[ -f "$SITE_ROOT/build/index.html" ]]; then
            WEB_DIR="$SITE_ROOT/build"
        else
            FOUND_INDEX=$(find "$SITE_ROOT" -maxdepth 3 -name "index.html" -type f | head -n1 || true)
            if [[ -n "$FOUND_INDEX" ]]; then
                WEB_DIR=$(dirname "$FOUND_INDEX")
            else
                warn "index.html not found in repository — falling back to built-in page."
                SITE_CHOICE="1"
            fi
        fi
    else
        warn "Failed to clone repository — falling back to built-in page."
        SITE_CHOICE="1"
    fi
fi

if [[ "$SITE_CHOICE" == "1" ]]; then
    WEB_DIR="$SITE_ROOT"
    cat > "${SITE_ROOT}/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${DOMAIN}</title>
  <style>
    body {
      margin: 0; font-family: system-ui, -apple-system, sans-serif;
      background: #0f172a; color: #e2e8f0;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; text-align: center;
    }
    .card {
      padding: 2.5rem; border-radius: 16px;
      background: #1e293b; box-shadow: 0 20px 40px rgba(0,0,0,0.4);
      max-width: 460px;
    }
    h1 { margin: 0 0 0.75rem; font-size: 1.75rem; color: #38bdf8; }
    p { margin: 0; color: #94a3b8; line-height: 1.6; }
  </style>
</head>
<body>
  <div class="card">
    <h1>${DOMAIN}</h1>
    <p>Personal project hub. Status: Online.</p>
  </div>
</body>
</html>
EOF
fi

FALLBACK_USER="nobody"
FALLBACK_GROUP="$(id -gn nobody)"
chown -R "${FALLBACK_USER}:${FALLBACK_GROUP}" "$SITE_ROOT"

cat > /etc/systemd/system/fallback-site.service << EOF
[Unit]
Description=Fallback Static Site for Xray
After=network.target

[Service]
Type=simple
User=${FALLBACK_USER}
Group=${FALLBACK_GROUP}
WorkingDirectory=${WEB_DIR}
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fallback-site
systemctl restart fallback-site
ok "Fallback site is running on 127.0.0.1:8080 (serving $WEB_DIR)."

# --- Step 11. Install 'vlessLink' helper command ---
info "Installing 'vlessLink' command..."
cat > /usr/local/bin/vlessLink << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
CERT="/usr/local/etc/xray/certs/fullchain.pem"
PROFILE_FILE="/usr/local/etc/xray/.profile_name"

if [[ ! -r "$CONFIG" || ! -r "$CERT" ]]; then
    echo "Error: Cannot read Xray config or SSL certificate. Try running as root (sudo vlessLink)." >&2
    exit 1
fi

DOMAIN=$(openssl x509 -in "$CERT" -noout -text | grep -oP 'DNS:\K[^,\s]+' | head -n1 || true)
if [[ -z "$DOMAIN" ]]; then
    echo "Error: Could not extract domain name from $CERT." >&2
    exit 1
fi

BASE_NAME="$DOMAIN"
if [[ -r "$PROFILE_FILE" ]]; then
    SAVED_NAME=$(tr -d '\r\n' < "$PROFILE_FILE")
    [[ -n "$SAVED_NAME" ]] && BASE_NAME="$SAVED_NAME"
fi

python3 - "$CONFIG" "$DOMAIN" "$BASE_NAME" << 'PY'
import json, sys, urllib.parse, subprocess, shutil

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)
domain = sys.argv[2]
base_name = sys.argv[3]

vless_in = next((ib for ib in cfg.get("inbounds", []) if ib.get("protocol") == "vless"), None)
if not vless_in:
    sys.exit("Error: VLESS inbound not found in config.json")

clients = vless_in.get("settings", {}).get("clients", [])
if not clients:
    sys.exit("Error: No clients found in VLESS inbound")

for i, c in enumerate(clients, 1):
    uuid = c["id"]
    name = base_name if len(clients) == 1 else f"{base_name}-{i}"
    tag = urllib.parse.quote(name)
    uri = (
        f"vless://{uuid}@{domain}:443"
        f"?type=tcp&encryption=none&flow=xtls-rprx-vision"
        f"&security=tls&sni={domain}&alpn=http%2F1.1&fp=chrome#{tag}"
    )
    print(f"\n=== Client #{i} (UUID: {uuid}) ===")
    print(uri)
    print()
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-t", "ansiutf8", uri], check=False)
PY
EOF
chmod 0755 /usr/local/bin/vlessLink

# --- Step 12. Print summary & connection info ---
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}                   SETUP COMPLETE!                          ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "HTTPS site: ${CYAN}https://${DOMAIN}${NC}"
echo -e "Check status: ${CYAN}systemctl status xray fallback-site --no-pager${NC}"
echo -e "Show link/QR again anytime: ${CYAN}vlessLink${NC}"

vlessLink
