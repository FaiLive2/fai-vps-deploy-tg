#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'
MAG='\033[0;35m'; CYN='\033[0;36m'; WHT='\033[1;37m'; NC='\033[0m'

rainbow_line() {
    local text="$1"; local colors=("$RED" "$YEL" "$GRN" "$CYN" "$BLU" "$MAG"); local i=0
    for (( j=0; j<${#text}; j++ )); do c=${colors[$((i % 6))]}; printf '%b%s%b' "$c" "${text:$j:1}" "$NC"; i=$((i+1)); done; echo ""
}

ascii_banner() {
    rainbow_line '  ___   ___     ___   _   __  __ ___ _  _  ___ '
    rainbow_line ' |   \ | __|   / __| /_\ |  \/  |_ _| \| |/ __|'
    rainbow_line ' | |) || _||  | (_ |/ _ \| |\/| || || .` | (_ |'
    rainbow_line ' |___/ |___|   \___/_/ \_\_|_|_|_|___|_|\_|\___|'
    echo ""
    rainbow_line ' ___  ___ _____   _   __  _____   ___ ___ ___ _____ ___ ___  _  _ '
    rainbow_line '| _ )/ _ \_   _| | |  \ \/ / __| | __|   \_ _|_   _|_ _/ _ \| \| |'
    rainbow_line '| _ \ (_) || |   | |__ >  < (__  | _|| |) | |  | |  | | (_) | .` |'
    rainbow_line '|___/\___/ |_|   |____/_/\_\___| |___|___/___| |_| |___\___/|_|\_|'
    echo ""
    rainbow_line '                    ~ Made by FaiLive2 ~'
    echo ""
}

banner() {
    clear; ascii_banner
    echo -e "${WHT}  ─────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${CYN}Fully Automated LXC/LXD VPS Telegram Bot Installer${NC}"
    echo -e "  ${CYN}Ubuntu & Debian supported | Fast setup${NC}"
    echo -e "  ${MAG}Made by FaiLive2${NC}  |  ${BLU}github.com/failive2/vps-deploy-bot${NC}"
    echo -e "${WHT}  ─────────────────────────────────────────────────────────────${NC}\n"
}

step()  { echo -e "${GRN}[+]${NC} $1"; }
warn()  { echo -e "${YEL}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }

need_root() { if [ "$EUID" -ne 0 ]; then err "Please run as root (sudo ./install.sh)"; exit 1; fi }

choose_os() {
    echo -e "${WHT}Select your OS:${NC}"
    echo -e "  ${YEL}1)${NC} Ubuntu"
    echo -e "  ${YEL}2)${NC} Debian"
    read -rp "$(echo -e "${CYN}Enter choice [1-2]: ${NC}")" OS_CHOICE
}

install_lxd_ubuntu() {
    step "Updating packages (Ubuntu)..."; apt update && apt upgrade -y
    step "Installing LXC, snapd, network dependencies..."; apt install -y lxc lxc-utils snapd bridge-utils uidmap
    step "Enabling snapd..."; systemctl enable --now snapd.socket
    step "Installing LXD via snap..."; snap install lxd || snap refresh lxd
    step "Configuring lxd permissions..."; if [ -n "${SUDO_USER:-}" ]; then usermod -aG lxd "$SUDO_USER" || true; fi
    step "Initializing LXD..."; lxd init --auto || warn "LXD already initialized."
}

install_lxd_debian() {
    step "Updating packages (Debian)..."; apt update && apt upgrade -y
    step "Installing snapd..."; apt install -y snapd; systemctl enable --now snapd.socket
    step "Linking snap directory..."; ln -sf /var/lib/snapd/snap /snap
    step "Installing LXD via snap..."; snap install lxd || snap refresh lxd
    step "Configuring lxd permissions..."; if [ -n "${SUDO_USER:-}" ]; then usermod -aG lxd "$SUDO_USER" || true; fi
    step "Initializing LXD..."; lxd init --auto || warn "LXD already initialized."
}

install_python_stack() {
    step "Installing Python 3 and pip..."; apt install -y python3-pip python3-full
    step "Configuring pip..."; mkdir -p /root/.config/pip; echo "[global]" > /root/.config/pip/pip.conf; echo "break-system-packages = true" >> /root/.config/pip/pip.conf
    step "Installing dependencies..."; pip3 install -U python-telegram-bot requests
}

deploy_bot() {
    step "Deploying bot.py to /root ..."; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/bot.py" ]; then cp "$SCRIPT_DIR/bot.py" /root/bot.py; else err "bot.py not found next to install.sh."; exit 1; fi
}

configure_env() {
    echo -e "\n${WHT}────────── Bot Configuration ──────────${NC}"
    read -rp "$(echo -e "${CYN}Enter your Telegram Bot Token: ${NC}")" TELEGRAM_BOT_TOKEN
    read -rp "$(echo -e "${CYN}Enter your Main Admin Telegram ID: ${NC}")" MAIN_ADMIN_ID
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$MAIN_ADMIN_ID" ]; then err "Token and Admin ID cannot be empty."; exit 1; fi
}

create_service() {
    step "Creating systemd service..."
    cat > /etc/systemd/system/tg-bot.service <<EOF
[Unit]
Description=FaiLive2 Cloud Telegram VPS Bot
After=network.target

[Service]
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/python3 /root/bot.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
Environment=MAIN_ADMIN_ID=${MAIN_ADMIN_ID}
Environment=BOT_NAME=FaiLive2 Cloud

[Install]
WantedBy=multi-user.target
EOF
    step "Reloading daemon..."; systemctl daemon-reload
    step "Enabling and starting bot service..."; systemctl enable --now tg-bot
}

final_message() {
    echo -e "\n${WHT}────────────────────────────────────────${NC}"
    echo -e "${GRN}  Installation complete!${NC}"
    echo -e "${WHT}────────────────────────────────────────${NC}"
    echo -e "  ${CYN}Service:${NC}   tg-bot.service"
    echo -e "  ${CYN}Status:${NC}    systemctl status tg-bot"
    echo -e "  ${CYN}Logs:${NC}      journalctl -u tg-bot -f"
    echo -e "  ${CYN}Restart:${NC}   systemctl restart tg-bot"
    echo -e "${WHT}────────────────────────────────────────${NC}\n"
}

main() {
    banner; need_root; choose_os
    case "$OS_CHOICE" in
        1) install_lxd_ubuntu ;;
        2) install_lxd_debian ;;
        *) err "Invalid choice."; exit 1 ;;
    esac
    install_python_stack; deploy_bot; configure_env; create_service; final_message
}

main "$@"
