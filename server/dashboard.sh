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
CURRENT_VERSION="2024.04.23_4"
REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"
REMOTE_VERSION=$(curl -s "$REMOTE_URL" | grep '^CURRENT_VERSION=' | cut -d= -f2 | tr -d '"')

bold=$(tput bold)
normal=$(tput sgr0)
blue=$(tput setaf 4)
green=$(tput setaf 2)
red=$(tput setaf 1)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
white=$(tput setaf 7)
ok="${green}●${normal}"
fail="${red}●${normal}"
warn="${yellow}●${normal}"
separator="${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${normal}"

if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
    echo "${yellow}🔔 Доступна новая версия MOTD-дашборда:${normal} ${green}$REMOTE_VERSION${normal} ${bold}(текущая: $CURRENT_VERSION)${normal}"
    echo "${cyan}💡 Обновление:${normal}"
    echo "   ${bold}curl -fsSL $REMOTE_URL | bash -s -- --force${normal}"
    echo ""
fi

echo "${normal}"
echo "${white}  — powered by https://NeoNode.cc${normal}"
echo "$separator"

uptime_str=$(uptime -p)
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8 "%"}')
mem_data=$(free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}')
disk_used=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
disk_line=$(df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}')
if [ "$disk_used" -ge 95 ]; then
    disk_status="${red}${disk_line}${normal} ${red}[CRITICAL: Free up space immediately!]❌${normal}"
elif [ "$disk_used" -ge 85 ]; then
    disk_status="${yellow}${disk_line}${normal} ${yellow}[Warning: High usage]⚠️${normal}"
else
    disk_status="${green}${disk_line}${normal}"
fi
traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
ip_local=$(hostname -I | awk '{print $1}')
ip_public=$(curl -s ifconfig.me || echo "n/a")
ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$ip6" ] && ip6="n/a"

if systemctl is-active crowdsec &>/dev/null; then
    bouncers=$(crowdsec-cli bouncers list 2>/dev/null | grep -v NAME | awk '{print $1 ": " $2}' | paste -sd ', ')
    [ -z "$bouncers" ] && crowdsec_status="$warn active, but no bouncers ⚠️" || crowdsec_status="$ok $bouncers"
else
    crowdsec_status="$fail not running ❌"
fi

if command -v docker &>/dev/null; then
    docker_total=$(docker ps -a -q | wc -l)
    docker_running=$(docker ps -q | wc -l)
    docker_stopped=$((docker_total - docker_running))
    docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
    bad_containers=$(docker ps -a --filter "status=exited" --filter "status=restarting" --format '⛔ {{.Names}} ({{.Status}})')
    if [ -n "$bad_containers" ]; then
        docker_msg="$fail Issues: $docker_running running / $docker_stopped stopped\n$bad_containers"
    fi
else
    docker_msg="$warn not installed ⚠️"
fi

ssh_users=$(who | wc -l)
ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)

if command -v fail2ban-client &>/dev/null; then
    fail2ban_status="$ok active"
else
    fail2ban_status="$fail not installed ❌"
fi

if command -v ufw &>/dev/null; then
    ufw_status=$(ufw status | grep -i "Status" | awk '{print $2}')
    if [[ "$ufw_status" == "active" ]]; then
        ufw_status="$ok enabled"
    else
        ufw_status="$fail disabled ❌"
    fi
else
    ufw_status="$fail not installed ❌"
fi

updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
update_msg="${updates} package(s) can be updated"

# 🔐 Безопасность: проверка настроек SSH
ssh_port=$(grep -Ei '^Port ' /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
[ -z "$ssh_port" ] && ssh_port=22
[ "$ssh_port" != "22" ] && ssh_port_status="$ok non-standard port ($ssh_port)" || ssh_port_status="$warn default port (22) ⚠️"

permit_root=$(grep -Ei '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print $2}')
[ "$permit_root" != "yes" ] && root_login_status="$ok disabled" || root_login_status="$fail enabled ❌"

password_auth=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
[ "$password_auth" != "yes" ] && password_auth_status="$ok disabled" || password_auth_status="$fail enabled ❌"

if dpkg -l | grep -q unattended-upgrades; then
    auto_update_status="$ok enabled"
else
    auto_update_status="$warn not installed ⚠️"
fi

printf "${bold}🧠 Uptime:        ${normal} %s\n" "$uptime_str"
printf "${bold}🧮 Load Average:  ${normal} %s\n" "$loadavg"
printf "${bold}⚙️  CPU Usage:     ${normal} %s\n" "$cpu_usage"
printf "${bold}💾 RAM Usage:     ${normal} %s\n" "$mem_data"
printf "${bold}💽 Disk Usage:    ${normal} %b\n" "$disk_status"
printf "${bold}📡 Net Traffic:   ${normal} %s\n" "$traffic"
printf "${bold}🔐 CrowdSec:      ${normal} %b\n" "$crowdsec_status"
printf "${bold}🐳 Docker:        ${normal} %b\n" "$docker_msg"
printf "${bold}👮 Fail2ban:      ${normal} %s\n" "$fail2ban_status"
printf "${bold}🧱 UFW Firewall:  ${normal} %s\n" "$ufw_status"
printf "${bold}👥 SSH Sessions:  ${normal} %s\n" "$ssh_users"
printf "${bold}🔗 SSH IPs:       ${normal} %s\n" "$ssh_ips"
printf "${bold}🌐 IP Address:    ${normal} Local: $ip_local | Public: $ip_public\n"
printf "${bold}🌍 IPv6 Address:   ${normal} $ip6\n"
printf "${bold}⬆️  Updates:       ${normal} $update_msg\n"
printf "${bold}🔐 SSH Port:      ${normal} %s\n" "$ssh_port_status"
printf "${bold}🚫 Root Login:    ${normal} %s\n" "$root_login_status"
printf "${bold}🔑 Password Auth: ${normal} %s\n" "$password_auth_status"
printf "${bold}📦 Auto Updates:  ${normal} %s\n" "$auto_update_status"
printf "${bold}🆕 Dashboard Ver: ${normal} $CURRENT_VERSION\n"
echo "$separator"
echo ""
echo "${bold}✔️  SYSTEM CHECK SUMMARY:${normal}"
[ "$updates" -eq 0 ] && echo "$ok Packages up to date" || echo "$warn Updates available ⚠️"
[[ "$docker_msg" == *"Issues:"* ]] && echo "$fail Docker issue ❌" || echo "$ok Docker OK"
[[ "$crowdsec_status" =~ "$fail" ]] && echo "$fail CrowdSec not working ❌" || echo "$ok CrowdSec OK"
[[ "$fail2ban_status" =~ "$fail" ]] && echo "$fail Fail2ban not installed ❌" || echo "$ok Fail2ban OK"
[[ "$ufw_status" =~ "$fail" ]] && echo "$fail UFW not enabled ❌" || echo "$ok UFW OK"
[[ "$root_login_status" =~ "$fail" ]] && echo "$fail Root login enabled ❌" || echo "$ok Root login disabled"
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
