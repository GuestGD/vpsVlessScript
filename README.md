# vpsVlessScript

An interactive bash script for quickly deploying a personal VPN server powered by **Xray-core (VLESS + TLS + XTLS-Vision)** with an HTTPS fallback website, automatic **Let's Encrypt** SSL renewal, **TCP BBR**, and **UFW** firewall.

## Requirements
* A fresh VPS with `root` access (ports `80` and `443` must be free — no running `nginx`, `apache2`, etc.).
* A domain name with an **A record** pointing to your VPS IP address (if using Cloudflare, keep the proxy / orange cloud **disabled**).

## Compatibility
* Configuration verified on **Ubuntu 22.04 LTS**.
* Supports **Ubuntu 22.04 / 24.04+** and **Debian 11 / 12+**.

## Installation

Connect to your VPS via SSH as `root` and run:

```bash
curl -fsSLO https://raw.githubusercontent.com/GuestGD/vpsVlessScript/main/install-vless.sh
chmod +x install-vless.sh
./install-vless.sh
```

> **Important:** Do **not** run via `curl ... | bash`. The script is interactive and reads your input from the terminal.

The script will ask for your domain, optional Let's Encrypt email, UUID (or auto-generate one), SSH port, and fallback site option, then automatically configure everything and print a ready-to-use `vless://` link and QR code for clients (`v2rayNG`, `v2rayTun`, `Hiddify`, `Nekobox`).

## What Gets Configured
* **Xray-core** on port `443` (`VLESS + TLS + xtls-rprx-vision`), running under the dedicated `xray` user.
* **Let's Encrypt (`certbot`)** with automatic SSL renewal and a deploy hook to update permissions and restart Xray.
* **Fallback static site** bound strictly to `127.0.0.1:8080` (`python3 -m http.server`, `alpn: http/1.1` for lightweight masking). Site root: `/var/www/fallback-site`.
* **TCP BBR + `fq`** for high throughput on lossy networks.
* **UFW firewall** allowing only your SSH port, `80/tcp`, and `443/tcp`.
* **`vlessLink`** helper command to display your connection link and QR code anytime.

## Useful Commands

Show your `vless://` link and QR code again:
```bash
vlessLink
```

Check service status:
```bash
systemctl status xray fallback-site --no-pager
```

Replace the fallback site with your own static files (HTML/JS/CSS):
```bash
# After uploading your archive to /tmp/site.zip
cd /var/www/fallback-site && rm -rf ./* && unzip -q /tmp/site.zip && chown -R nobody:$(id -gn nobody) /var/www/fallback-site && systemctl restart fallback-site
```
