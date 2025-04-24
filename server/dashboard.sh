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

CURRENT_VERSION="2025.04.24_build11"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"
REMOTE_VERSION=$(curl -s "$REMOTE_URL" | grep '^CURRENT_VERSION=' | cut -d= -f2 | tr -d '"')

ok="✅"
fail="❌"
warn="⚠️"
separator="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

print_section() {
  case "$1" in
    uptime) echo "🧠 Uptime:        $uptime_str" ;;
    load) echo "🧮 Load Average:  $loadavg" ;;
    cpu) echo "⚙️ CPU Usage:     $cpu_usage" ;;
    kernel) echo "🧬 Kernel:         $(uname -r)" ;;
    ram) echo "💾 RAM Usage:     $mem_data" ;;
    disk) echo "💽 Disk Usage:    $disk_status" ;;
    net) echo "📡 Net Traffic:   $traffic" ;;
    ip) echo "🌐 IP Address:    Local: $ip_local | Public: $ip_public | IPv6: $ip6" ;;
    docker)
      echo -e "🐳 Docker:        $docker_msg"
      [ -n "$docker_msg_extra" ] && echo -e "$docker_msg_extra"
      ;;
    ssh_block)
      echo "↓↓↓ Secure status block ↓↓↓"
      echo "👮 Fail2ban:      $fail2ban_status"
      echo "🔐 CrowdSec:      $crowdsec_status"
      echo "🧱 UFW Firewall:  $ufw_status"
      echo "🔐 SSH Port:      $ssh_port_status"
      echo "🚫 Root Login:    $root_login_status"
      echo "🔑 Password Auth: $password_auth_status"
      echo "👥 SSH Sessions:  $ssh_users"
      echo "🔗 SSH IPs:       $ssh_ips"
      ;;
    updates) echo "⬆️ Updates:       $update_msg" ;;
    autoupdates)
      echo "📦 Auto Updates:  $auto_update_status"
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
  esac
}

echo "  — powered by https://NeoNode.cc"
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

echo "🆕 Dashboard Ver: $CURRENT_VERSION"
echo "$separator"
echo "⚙️ Настройка отображения: motd-config"
EOF

chmod +x "$DASHBOARD_FILE"
# === Установка CLI-утилиты motd-config ===
cat > "$MOTD_CONFIG_TOOL" << 'EOF'
#!/bin/bash

CONFIG_FILE="$HOME/.motdrc"
USE_GLOBAL=false

for arg in "$@"; do
    if [ "$arg" == "--not-root" ]; then
        CONFIG_FILE="$HOME/.motdrc"
        USE_GLOBAL=false
    fi
done

if [ "$EUID" -eq 0 ] && [ "$USE_GLOBAL" = false ]; then
    read -p "🔧 Настроить глобально для всех пользователей (/etc/motdrc)? [y/N]: " global_choice
    if [[ "$global_choice" =~ ^[Yy]$ ]]; then
        CONFIG_FILE="/etc/motdrc"
        USE_GLOBAL=true
    fi
fi

declare -A BLOCKS=(
    [SHOW_UPTIME]="Uptime"
    [SHOW_LOAD]="Load Average"
    [SHOW_CPU]="CPU Usage"
    [SHOW_RAM]="RAM Usage"
    [SHOW_DISK]="Disk Usage"
    [SHOW_NET]="Network Traffic"
    [SHOW_IP]="IP Address"
    [SHOW_DOCKER]="Docker"
    [SHOW_SSH]="SSH Info"
    [SHOW_SECURITY]="Security (CrowdSec, UFW, Fail2ban)"
    [SHOW_UPDATES]="Apt Updates"
    [SHOW_AUTOUPDATES]="Auto Updates"
)

echo "🛠️ Конфигуратор MOTD"
echo "Файл: $CONFIG_FILE"
echo ""

> "$CONFIG_FILE"

for key in "${!BLOCKS[@]}"; do
    read -p "❓ Показывать ${BLOCKS[$key]}? [Y/n]: " answer
    case "$answer" in
        [Nn]*) echo "$key=false" >> "$CONFIG_FILE" ;;
        *)     echo "$key=true" >> "$CONFIG_FILE" ;;
    esac
done

echo ""
echo "✅ Конфигурация сохранена в $CONFIG_FILE"
EOF

chmod +x "$MOTD_CONFIG_TOOL"

# === Дефолтный глобальный конфиг ===
cat > "$CONFIG_GLOBAL" << EOF
SHOW_UPTIME=true
SHOW_LOAD=true
SHOW_CPU=true
SHOW_RAM=true
SHOW_DISK=true
SHOW_NET=true
SHOW_IP=true
SHOW_DOCKER=true
SHOW_SSH=true
SHOW_SECURITY=true
SHOW_UPDATES=true
SHOW_AUTOUPDATES=true
EOF

echo "✅ Установлен дашборд: $DASHBOARD_FILE"
echo "✅ Установлена CLI утилита: motd-config"
echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
echo ""
echo "👉 Для настройки блоков — запусти: motd-config"
echo "👉 MOTD появится при следующем входе"

