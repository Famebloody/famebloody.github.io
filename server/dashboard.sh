#!/bin/bash

DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
FORCE_MODE=false

# Обработка аргументов
for arg in "$@"; do
    case $arg in
        --force)
            FORCE_MODE=true
            shift
            ;;
    esac
done

# Проверка UTF-8
if ! locale | grep -qi 'utf-8'; then
    echo "⚠️ Внимание: терминал не использует UTF-8. Возможны искажения вывода."
fi

# Установка vnstat, если отсутствует
if ! command -v vnstat &>/dev/null; then
    echo "📦 Устанавливается vnstat..."
    apt update && apt install -y vnstat
    systemctl enable vnstat --now
fi

# Временный файл
TMP_FILE=$(mktemp)

# Создание MOTD скрипта
/bin/cat > "$TMP_FILE" << 'EOF'
#!/bin/bash
CURRENT_VERSION="2024.04.23_7"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"
REMOTE_VERSION=$(curl -s "$REMOTE_URL" | grep '^CURRENT_VERSION=' | cut -d= -f2 | tr -d '"')

ok="✅"
fail="❌"
warn="⚠️"
separator="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
    echo "${warn} Доступна новая версия MOTD-дашборда: $REMOTE_VERSION (текущая: $CURRENT_VERSION)"
    echo "💡 Обновление:"
    echo "   curl -fsSL $REMOTE_URL | bash -s -- --force"
    echo ""
fi

echo ""
echo "  — powered by https://NeoNode.cc"
echo "$separator"

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

if systemctl is-active crowdsec &>/dev/null; then
    bouncers=$(crowdsec-cli bouncers list 2>/dev/null | grep -v NAME | awk '{print $1 ": " $2}' | paste -sd ', ')
    [ -z "$bouncers" ] && crowdsec_status="$warn active, but no bouncers" || crowdsec_status="$ok $bouncers"
else
    crowdsec_status="$fail not running"
fi

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

updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
update_msg="${updates} package(s) can be updated"

# 🔐 Безопасность: проверка настроек SSH
ssh_port=$(grep -Ei '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
[ -z "$ssh_port" ] && ssh_port=22
[ "$ssh_port" != "22" ] && ssh_port_status="$ok non-standard port ($ssh_port)" || ssh_port_status="$warn default port (22)"

permit_root=$(grep -Ei '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print $2}')
[ "$permit_root" != "yes" ] && root_login_status="$ok disabled" || root_login_status="$fail enabled"

password_auth=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
[ "$password_auth" != "yes" ] && password_auth_status="$ok disabled" || password_auth_status="$fail enabled"

if dpkg -l | grep -q unattended-upgrades; then
    auto_update_status="$ok enabled"
else
    auto_update_status="$warn not installed"
fi

echo "🧠 Uptime:        $uptime_str"
echo "🧮 Load Average:  $loadavg"
echo "⚙️  CPU Usage:     $cpu_usage"
echo "💾 RAM Usage:     $mem_data"
echo "💽 Disk Usage:    $disk_status"
echo "📡 Net Traffic:   $traffic"
echo "🔐 CrowdSec:      $crowdsec_status"
echo -e "🐳 Docker:        $docker_msg"
[ -n "$docker_msg_extra" ] && echo -e "$docker_msg_extra"
echo "👮 Fail2ban:      $fail2ban_status"
echo "🧱 UFW Firewall:  $ufw_status"
echo "👥 SSH Sessions:  $ssh_users"
echo "🔗 SSH IPs:       $ssh_ips"
echo "🌐 IP Address:    Local: $ip_local | Public: $ip_public"
echo "🌍 IPv6 Address:   $ip6"
echo "🧬 Kernel:         $(uname -r)"
echo "⬆️  Updates:       $update_msg"
echo "🔐 SSH Port:      $ssh_port_status"
echo "🚫 Root Login:    $root_login_status"
echo "🔑 Password Auth: $password_auth_status"
echo "📦 Auto Updates:  $auto_update_status"
echo "🆕 Dashboard Ver: $CURRENT_VERSION"
echo "$separator"
echo ""
echo "✔️  SYSTEM CHECK SUMMARY:"
[ "$updates" -eq 0 ] && echo "$ok Packages up to date" || echo "$warn Updates available"
[[ "$docker_msg" == *"Issues:"* ]] && echo "$fail Docker issue" || echo "$ok Docker OK"
[[ "$crowdsec_status" =~ "$fail" ]] && echo "$fail CrowdSec not working" || echo "$ok CrowdSec OK"
[[ "$fail2ban_status" =~ "$fail" ]] && echo "$fail Fail2ban not installed" || echo "$ok Fail2ban OK"
[[ "$ufw_status" =~ "$fail" ]] && echo "$fail UFW not enabled" || echo "$ok UFW OK"
[[ "$root_login_status" =~ "$fail" ]] && echo "$fail Root login enabled" || echo "$ok Root login disabled"
echo ""
EOF

# Предпросмотр
clear
echo "===================================================="
echo "📋 Предпросмотр NeoNode MOTD (реальный вывод):"
echo "===================================================="
bash "$TMP_FILE"
echo "===================================================="

if [ "$FORCE_MODE" = true ]; then
    echo "⚙️ Автоматическая установка без подтверждения (--force)"
    mv "$TMP_FILE" "$DASHBOARD_FILE"
    chmod +x "$DASHBOARD_FILE"
    find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
    echo "✅ Установлено: $DASHBOARD_FILE"
else
    read -p '❓ Установить этот MOTD-дэшборд? [y/N]: ' confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mv "$TMP_FILE" "$DASHBOARD_FILE"
        chmod +x "$DASHBOARD_FILE"
        find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
        echo "✅ Установлено: $DASHBOARD_FILE"
    else
        echo "❌ Установка отменена."
        rm -f "$TMP_FILE"
    fi
fi
