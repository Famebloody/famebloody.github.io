#!/bin/bash

# === Настройки ===
DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
CONFIG_GLOBAL="/etc/motdrc"
MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"

FORCE_MODE=false
INSTALL_USER_MODE=false

# === Обработка аргументов ===
for arg in "$@"; do
    case $arg in
        --force)
            FORCE_MODE=true
            ;;
        --not-root)
            INSTALL_USER_MODE=true
            ;;
    esac
    shift
done

# === Проверка прав ===
if [ "$EUID" -ne 0 ] && [ "$INSTALL_USER_MODE" = false ]; then
    echo "❌ Пожалуйста, запусти от root или с флагом --not-root"
    exit 1
fi

# === Создание dashboard-файла ===
mkdir -p /etc/update-motd.d
cat > "$DASHBOARD_FILE" << 'EOF'
#!/bin/bash

CURRENT_VERSION="2025.04.24_build14"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"

ok="✅"
fail="❌"
warn="⚠️"
separator="─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

CONFIG_GLOBAL="/etc/motdrc"
CONFIG_USER="$HOME/.motdrc"
[ -f "$CONFIG_GLOBAL" ] && source "$CONFIG_GLOBAL"
[ -f "$CONFIG_USER" ] && source "$CONFIG_USER"

: "${SHOW_UPTIME:=true}"
: "${SHOW_LOAD:=true}"
: "${SHOW_CPU:=true}"
: "${SHOW_RAM:=true}"
: "${SHOW_DISK:=true}"
: "${SHOW_NET:=true}"
: "${SHOW_IP:=true}"
: "${SHOW_DOCKER:=true}"
: "${SHOW_SSH:=true}"
: "${SHOW_SECURITY:=true}"
: "${SHOW_UPDATES:=true}"
: "${SHOW_AUTOUPDATES:=true}"

uptime_str=$(uptime -p)
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8 "%"}')
mem_data=$(free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}')
disk_used=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
disk_line=$(df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}')
if [ "$disk_used" -ge 95 ]; then
    disk_status="$fail $disk_line [CRITICAL: Free up space immediately!]"
elif [ "$disk_used" -ge 85 ]; then
    disk_status="$warn $disk_line [Warning: High usage]"
else
    disk_status="$ok $disk_line"
fi

traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
ip_local=$(hostname -I | awk '{print $1}')
ip_public=$(curl -s ifconfig.me || echo "n/a")
ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$ip6" ] && ip6="n/a"

if command -v docker &>/dev/null; then
    docker_total=$(docker ps -a -q | wc -l)
    docker_running=$(docker ps -q | wc -l)
    docker_stopped=$((docker_total - docker_running))
    docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
    bad_containers=$(docker ps -a --filter "status=exited" --filter "status=restarting" --format '⛔ {{.Names}} ({{.Status}})')
    if [ -n "$bad_containers" ]; then
        docker_msg="$fail Issues: $docker_running running / $docker_stopped stopped"
        docker_msg_extra=$(echo "$bad_containers" | sed 's/^/                    /')
    fi
else
    docker_msg="$warn not installed"
fi

ssh_users=$(who | wc -l)
ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)

if command -v fail2ban-client &>/dev/null; then
    fail2ban_status="$ok active"
else
    fail2ban_status="$fail not installed"
fi

if command -v ufw &>/dev/null; then
    ufw_status=$(ufw status | grep -i "Status" | awk '{print $2}')
    if [[ "$ufw_status" == "active" ]]; then
        ufw_status="$ok enabled"
    else
        ufw_status="$fail disabled"
    fi
else
    ufw_status="$fail not installed"
fi

if systemctl is-active crowdsec &>/dev/null; then
    crowdsec_status="$ok active"
else
    crowdsec_status="$fail not running"
fi

ssh_port=$(grep -Ei '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
[ -z "$ssh_port" ] && ssh_port=22
[ "$ssh_port" != "22" ] && ssh_port_status="$ok non-standard port ($ssh_port)" || ssh_port_status="$warn default port (22)"

permit_root=$(sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
case "$permit_root" in
    yes) root_login_status="$fail enabled" ;;
    no) root_login_status="$ok disabled" ;;
    *) root_login_status="$warn limited ($permit_root)" ;;
esac

password_auth=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
[ "$password_auth" != "yes" ] && password_auth_status="$ok disabled" || password_auth_status="$fail enabled"

updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
update_msg="${updates} package(s) can be updated"

auto_update_status=""
if dpkg -s unattended-upgrades &>/dev/null && command -v unattended-upgrade &>/dev/null; then
    if grep -q 'Unattended-Upgrade "1";' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
        if systemctl is-enabled apt-daily.timer &>/dev/null && systemctl is-enabled apt-daily-upgrade.timer &>/dev/null; then
            if grep -q "Installing" /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null; then
                auto_update_status="$ok working"
            else
                auto_update_status="$ok enabled"
            fi
        else
            auto_update_status="$warn config enabled, timers disabled"
        fi
    else
        auto_update_status="$warn installed, config disabled"
    fi
else
    auto_update_status="$fail not installed"
fi

print_row() {
    local label="$1"
    local value="$2"
    printf " %-20s : %s\n" "$label" "$value"
}

print_section() {
  case "$1" in
    uptime)       print_row "System Uptime" "$uptime_str" ;;
    load)         print_row "Load Average" "$loadavg" ;;
    cpu)          print_row "CPU Usage" "$cpu_usage" ;;
    kernel)       print_row "Kernel" "$(uname -r)" ;;
    ram)          print_row "RAM Usage" "$mem_data" ;;
    disk)         print_row "Disk Usage" "$disk_status" ;;
    net)          print_row "Net Traffic" "$traffic" ;;
    ip)           print_row "IPv4/IPv6" "Local: $ip_local / Public: $ip_public / IPv6: $ip6" ;;
    docker)
      print_row "Docker" "$docker_msg"
      [ -n "$docker_msg_extra" ] && echo -e "$docker_msg_extra"
      ;;
    updates)      print_row "Apt Updates" "$update_msg" ;;
    autoupdates)
      print_row "Auto Updates" "$auto_update_status"
      case "$auto_update_status" in
        *"$fail"*)
          echo "📌 Auto-Upgrades not installed. To install and enable:"
          echo "   apt install unattended-upgrades -y"
          echo "   dpkg-reconfigure --priority=low unattended-upgrades"
          ;;
        *"timers disabled"*)
          echo "📌 Auto-Upgrades config enabled, but timers are off. To enable:"
          echo "   systemctl enable --now apt-daily.timer apt-daily-upgrade.timer"
          ;;
        *"config disabled"*)
          echo "📌 Auto-Upgrades installed, but config disabled. To fix:"
          echo "   echo 'APT::Periodic::Unattended-Upgrade \"1\";' >> /etc/apt/apt.conf.d/20auto-upgrades"
          echo "   systemctl restart apt-daily.timer apt-daily-upgrade.timer"
          ;;
      esac
      ;;
    ssh_block)
      echo " ↓↓↓ Security Block ↓↓↓"
      print_row "Fail2ban" "$fail2ban_status"
      print_row "CrowdSec" "$crowdsec_status"
      print_row "UFW Firewall" "$ufw_status"
      print_row "SSH Port" "$ssh_port_status"
      print_row "Root Login" "$root_login_status"
      print_row "Password Auth" "$password_auth_status"
      print_row "SSH Sessions" "$ssh_users"
      print_row "SSH IPs" "$ssh_ips"
      echo " ↑↑↑ Security Block ↑↑↑"
      ;;
  esac
}

echo "$separator"
echo " MOTD Dashboard — powered by https://NeoNode.cc"
echo "$separator"
[ "$SHOW_UPTIME" = true ] && print_section uptime
[ "$SHOW_LOAD" = true ] && print_section load
[ "$SHOW_CPU" = true ] && print_section cpu
print_section kernel
[ "$SHOW_RAM" = true ] && print_section ram
[ "$SHOW_DISK" = true ] && print_section disk
[ "$SHOW_NET" = true ] && print_section net
[ "$SHOW_IP" = true ] && print_section ip
[ "$SHOW_DOCKER" = true ] && print_section docker
[ "$SHOW_SECURITY" = true ] && print_section ssh_block
[ "$SHOW_UPDATES" = true ] && print_section updates
[ "$SHOW_AUTOUPDATES" = true ] && print_section autoupdates

# === Проверка версии дашборда ===
if curl -fsSL "$REMOTE_URL" >/dev/null; then
    REMOTE_VERSION=$(curl -s "$REMOTE_URL" | grep 'CURRENT_VERSION="' | sed -n 's/^.*CURRENT_VERSION=\"\([^"]*\)\".*/\1/p')
    if [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ] && [ -n "$REMOTE_VERSION" ]; then
        echo "📣 Доступна новая версия дашборда: $REMOTE_VERSION (текущая: $CURRENT_VERSION)"
        echo "🔄 Обновить: curl -fsSL $REMOTE_URL | bash -s -- --force"
    fi
fi

printf " %-20s : %s\n" "Dashboard Ver" "$CURRENT_VERSION"
echo "$separator"
printf " %-20s : %s\n" "Config tool" "motd-config"
EOF
