#!/bin/bash

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

F2B_HELPER="/usr/local/bin/f2b"

function print_header() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${GREEN}Fail2Ban SSH Security Installer${NC}"
  echo -e "${BLUE}========================================${NC}"
}

function check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root.${NC}"
    exit 1
  fi
}

function install_fail2ban() {
  if ! command -v fail2ban-server &>/dev/null; then
    echo -e "${YELLOW}Installing Fail2ban...${NC}"
    apt update && apt install -y fail2ban || { echo -e "${RED}Failed to install fail2ban${NC}"; exit 1; }
  fi
}

function detect_ssh_port() {
  SSH_PORT=$(grep -Po '(?<=^Port )\d+' /etc/ssh/sshd_config | head -n1)
  SSH_PORT=${SSH_PORT:-22}
  echo -e "${CYAN}Detected SSH port:${NC} ${GREEN}$SSH_PORT${NC}"
}

function backup_and_configure_fail2ban() {
  JAIL_LOCAL="/etc/fail2ban/jail.local"
  cp -f "$JAIL_LOCAL" "${JAIL_LOCAL}.bak_$(date +%Y%m%d_%H%M%S)" 2>/dev/null

  cat > "$JAIL_LOCAL" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime.increment = true
bantime.factor = 2
bantime.formula = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor
bantime.maxtime = 1w
findtime = 10m
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
EOF

  echo -e "${GREEN}Fail2ban configured with dynamic SSH blocking.${NC}"
}

function restart_fail2ban() {
  systemctl restart fail2ban
  sleep 1
  if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}Fail2ban service is running.${NC}"
  else
    echo -e "${RED}Fail2ban failed to start. Check the config!${NC}"
    fail2ban-client -d
    exit 1
  fi
}

function allow_firewall_port() {
  if command -v ufw > /dev/null; then
    ufw allow "$SSH_PORT"/tcp || true
    echo -e "${YELLOW}UFW: allowed SSH port $SSH_PORT${NC}"
  fi
}

function create_f2b_helper() {
  cat > "$F2B_HELPER" <<'EOF'
#!/bin/bash

case "$1" in
  status)
    systemctl status fail2ban
    ;;
  restart)
    systemctl restart fail2ban && echo "Fail2ban restarted."
    ;;
  list)
    fail2ban-client status sshd
    ;;
  banned)
    fail2ban-client status sshd | grep 'Banned IP list' || echo "No bans recorded."
    ;;
  log)
    tail -n 50 /var/log/fail2ban.log
    ;;
  help|*)
    echo "Fail2ban Helper (f2b)"
    echo "Usage:"
    echo "  f2b status     - Show Fail2ban system status"
    echo "  f2b restart    - Restart Fail2ban"
    echo "  f2b list       - Show jail status and stats"
    echo "  f2b banned     - Show list of banned IPs"
    echo "  f2b log        - Tail fail2ban log"
    echo "  f2b help       - Show this help"
    ;;
esac
EOF
  chmod +x "$F2B_HELPER"
  echo -e "${GREEN}Helper command created: ${CYAN}f2b${NC}"
}

function uninstall_f2b_helper() {
  if [ -f "$F2B_HELPER" ]; then
    rm -f "$F2B_HELPER"
    echo -e "${YELLOW}Removed f2b helper from ${F2B_HELPER}${NC}"
  else
    echo -e "${RED}No helper found at ${F2B_HELPER}${NC}"
  fi
}

case "$1" in
  uninstall-helper)
    uninstall_f2b_helper
    exit 0
    ;;
  install-helper)
    create_f2b_helper
    exit 0
    ;;
esac

print_header
check_root
install_fail2ban
detect_ssh_port
backup_and_configure_fail2ban
restart_fail2ban
allow_firewall_port
create_f2b_helper

echo -e "\n${BLUE}You can now use 'f2b' command to manage fail2ban easily:${NC}"
echo -e "  ${CYAN}f2b status${NC}     - show systemd status"
echo -e "  ${CYAN}f2b list${NC}       - show banned IPs and jail stats"
echo -e "  ${CYAN}f2b banned${NC}     - list only banned IPs"
echo -e "  ${CYAN}f2b log${NC}        - tail fail2ban log"
echo -e "  ${CYAN}f2b restart${NC}    - restart fail2ban"
echo -e "  ${CYAN}f2b help${NC}       - show this help"
echo -e "\n${GREEN}Fail2ban SSH protection is now active.${NC}"
