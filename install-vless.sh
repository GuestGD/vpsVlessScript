#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Интерактивный установщик Xray (VLESS + TLS + XTLS-Vision) с Fallback-сайтом,
# автопродлением SSL (Let's Encrypt), TCP BBR и UFW.
# Поддерживаемые ОС: Ubuntu 22.04/24.04+, Debian 11/12+
# ==============================================================================

# При необходимости зафиксировать конкретную версию Xray-core, укажите её ниже
# (например, "v26.10.31"). Пустое значение = всегда последняя версия.
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
    echo -e "${RED}[FATAL]${NC} Сбой на строке ${line} при выполнении команды: ${cmd}"
    echo -e "${YELLOW}Проверьте вывод выше. Если сбой произошёл на этапе certbot, убедитесь, что DNS-запись домена указывает на IP этого сервера и порт 80 свободен.${NC}"
    exit 1
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# --- Проверка прав и ОС ---
[[ $EUID -eq 0 ]] || error "Запустите скрипт от имени root (sudo bash $0)."
command -v apt-get >/dev/null 2>&1 || error "Поддерживаются только Debian и Ubuntu (apt-get)."

clear || true
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Установка VLESS (TLS + XTLS-Vision) + Fallback + BBR     ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# --- Шаг 1. Интерактивный ввод данных ---
while true; do
    read -rp "1. Введите ваш домен (например, vpn.example.com): " DOMAIN
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN%%/*}"
    if [[ -n "$DOMAIN" && "$DOMAIN" == *.* && "$DOMAIN" != *" "* ]]; then
        break
    fi
    warn "Некорректный домен. Попробуйте снова."
done

read -rp "2. Email для уведомлений Let's Encrypt (Enter — пропустить): " CERT_EMAIL

while true; do
    read -rp "3. Введите UUID (Enter — сгенерировать новый автоматически): " USER_UUID
    if [[ -z "$USER_UUID" ]]; then
        USER_UUID=$(cat /proc/sys/kernel/random/uuid)
        info "Сгенерирован новый UUID: $USER_UUID"
        break
    elif [[ "$USER_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        break
    else
        warn "Некорректный формат UUID (ожидается xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
    fi
done

read -rp "4. Название профиля в VPN-клиенте [по умолчанию: $DOMAIN]: " PROFILE_NAME
PROFILE_NAME="${PROFILE_NAME:-$DOMAIN}"

read -rp "5. Порт SSH на этом сервере [по умолчанию: 22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    error "Некорректный порт SSH: $SSH_PORT"
fi

echo ""
echo "6. Сайт-заглушка (откроется при заходе на https://$DOMAIN в браузере):"
echo "   1) Встроенная лёгкая HTML-страница (надёжно, не зависит от сторонних репо)"
echo "   2) Скачать статический сайт из публичного Git-репозитория (HTML/JS/CSS)"
read -rp "Выберите вариант [1/2, по умолчанию 1]: " SITE_CHOICE
SITE_CHOICE="${SITE_CHOICE:-1}"

GIT_REPO_URL=""
if [[ "$SITE_CHOICE" == "2" ]]; then
    read -rp "   Введите HTTPS-ссылку на репозиторий (например, https://github.com/user/site.git): " GIT_REPO_URL
    [[ -n "$GIT_REPO_URL" ]] || error "URL репозитория не может быть пустым."
fi

echo ""
read -rp "Начать установку с указанными параметрами? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Установка отменена."; exit 0; }

# --- Шаг 2. Установка зависимостей ---
info "Обновление списков пакетов и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl openssl unzip python3 qrencode ufw git certbot

# --- Шаг 3. Жёсткая проверка портов и DNS ---
info "Проверка портов 80 и 443..."
if ss -tlnp | grep -qE ':(80|443)\s'; then
    echo -e "${RED}Порты 80 или 443 уже заняты другим сервисом:${NC}"
    ss -tlnp | grep -E ':(80|443)\s' || true
    error "Остановите мешающий веб-сервер/прокси (например, nginx, apache2 или старый xray) и запустите скрипт снова."
fi
ok "Порты 80 и 443 свободны."

info "Проверка DNS-записи домена $DOMAIN..."
SERVER_IP=$(
    curl -4 -s --max-time 8 https://api.ipify.org \
    || curl -4 -s --max-time 8 https://ifconfig.me \
    || curl -4 -s --max-time 8 https://icanhazip.com \
    || true
)
SERVER_IP="${SERVER_IP//$'\n'/}"
DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1 || true)

if [[ -z "$SERVER_IP" ]]; then
    warn "Не удалось определить внешний IPv4 этого сервера через публичные сервисы. Пропускаем автосверку DNS."
elif [[ -z "$DOMAIN_IP" ]]; then
    warn "Не удалось определить A-запись домена $DOMAIN."
    read -rp "Продолжить всё равно? Certbot может не выдать сертификат [y/N]: " DNS_CONT
    [[ "$DNS_CONT" =~ ^[Yy]$ ]] || exit 1
elif [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    warn "A-запись домена ($DOMAIN_IP) не совпадает с IP этого сервера ($SERVER_IP)!"
    warn "Убедитесь, что DNS прописан верно и отключён прокси Cloudflare (оранжевое облако)."
    read -rp "Продолжить всё равно? [y/N]: " DNS_CONT
    [[ "$DNS_CONT" =~ ^[Yy]$ ]] || exit 1
else
    ok "DNS настроен верно: $DOMAIN -> $DOMAIN_IP"
fi

# --- Шаг 4. Включение TCP BBR ---
info "Включение TCP BBR + fq..."
cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null
ok "Алгоритм управления перегрузкой: $(sysctl -n net.ipv4.tcp_congestion_control)"

# --- Шаг 5. Настройка файрвола UFW ---
info "Настройка UFW (порты $SSH_PORT, 80, 443)..."
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
systemctl enable ufw >/dev/null 2>&1 || true
ok "UFW включён и настроен."

# --- Шаг 6. Получение SSL-сертификата Let's Encrypt ---
info "Получение SSL-сертификата для $DOMAIN..."
CERTBOT_ARGS=(certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos)
if [[ -n "$CERT_EMAIL" ]]; then
    CERTBOT_ARGS+=(-m "$CERT_EMAIL")
else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
fi
certbot "${CERTBOT_ARGS[@]}"
ok "Сертификат успешно получен."

# --- Шаг 7. Установка Xray-core ---
info "Установка Xray-core..."
XRAY_INSTALL_ARGS=(install)
if [[ -n "$XRAY_VERSION" ]]; then
    XRAY_INSTALL_ARGS+=(--version "$XRAY_VERSION")
fi
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ "${XRAY_INSTALL_ARGS[@]}"

# Определяем системного пользователя Xray (с 18.10.2026 это xray, ранее — nobody)
if id -u xray >/dev/null 2>&1; then
    XRAY_USER="xray"
else
    XRAY_USER="nobody"
fi
XRAY_GROUP="$(id -gn "$XRAY_USER")"
info "Сервис Xray использует пользователя: ${XRAY_USER}:${XRAY_GROUP}"

mkdir -p /usr/local/etc/xray/certs /var/log/xray
chown root:"$XRAY_GROUP" /usr/local/etc/xray /usr/local/etc/xray/certs
chmod 0750 /usr/local/etc/xray /usr/local/etc/xray/certs
chown -R "${XRAY_USER}:${XRAY_GROUP}" /var/log/xray
chmod 0700 /var/log/xray

# --- Шаг 8. Хук автообновления SSL для Xray ---
info "Настройка автоматического обновления сертификатов для Xray..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/xray-certs.sh << EOF
#!/usr/bin/env bash
set -e
DOMAIN="${DOMAIN}"
CERT_DIR="/usr/local/etc/xray/certs"
XRAY_USER="${XRAY_USER}"
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

# Первый запуск хука для копирования сертификатов
/etc/letsencrypt/renewal-hooks/deploy/xray-certs.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

# --- Шаг 9. Конфигурация Xray ---
info "Создание конфигурации /usr/local/etc/xray/config.json..."
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

chown root:"$XRAY_GROUP" /usr/local/etc/xray/config.json
chmod 0640 /usr/local/etc/xray/config.json

# Проверяем конфиг И права доступа к сертификатам именно от имени пользователя Xray
runuser -u "$XRAY_USER" -- /usr/local/bin/xray -test -config /usr/local/etc/xray/config.json
systemctl enable xray
systemctl restart xray
ok "Xray успешно запущен."

# --- Шаг 10. Изолированный fallback-сайт на 127.0.0.1:8080 ---
info "Настройка сайта-заглушки на 127.0.0.1:8080..."
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
                warn "index.html не найден в репозитории — используем встроенную заглушку."
                SITE_CHOICE="1"
            fi
        fi
    else
        warn "Не удалось клонировать репозиторий — используем встроенную заглушку."
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
ok "Fallback-сайт запущен на 127.0.0.1:8080 (из папки $WEB_DIR)."

# --- Шаг 11. Формирование клиентской ссылки и QR-кода ---
ENCODED_TAG=$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))' "$PROFILE_NAME")
VLESS_URI="vless://${USER_UUID}@${DOMAIN}:443?type=tcp&encryption=none&flow=xtls-rprx-vision&security=tls&sni=${DOMAIN}&alpn=http%2F1.1&fp=chrome#${ENCODED_TAG}"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}                  УСТАНОВКА ЗАВЕРШЕНА!                      ${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "Домен (HTTPS-сайт): ${CYAN}https://${DOMAIN}${NC}"
echo -e "UUID клиента:       ${CYAN}${USER_UUID}${NC}"
echo ""
echo -e "${YELLOW}Ссылка для импорта (v2rayNG / v2rayTun / Nekobox / Hiddify):${NC}"
echo "$VLESS_URI"
echo ""
echo -e "${YELLOW}QR-код для телефона:${NC}"
qrencode -t ansiutf8 "$VLESS_URI"
echo ""
echo -e "${CYAN}Проверка статуса сервисов:${NC}"
echo "  systemctl status xray fallback-site --no-pager"