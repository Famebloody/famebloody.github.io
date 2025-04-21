
#!/bin/bash

DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"

# Предпросмотр контента скрипта
read -r -d '' DASHBOARD_CONTENT <<'EOF'
#!/bin/bash

# Цвета
bold=$(tput bold)
normal=$(tput sgr0)
blue=$(tput setaf 4)
green=$(tput setaf 2)
red=$(tput setaf 1)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
white=$(tput setaf 7)
separator="${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${normal}"

# Логотип
echo "${cyan}${bold}"
echo "███╗   ██╗███████╗ ██████╗ ███╗   ██╗ ██████╗ ██████╗ ███████╗"
echo "████╗  ██║██╔════╝██╔═══██╗████╗  ██║██╔═══██╗██╔══██╗██╔════╝"
echo "██╔██╗ ██║█████╗  ██║   ██║██╔██╗ ██║██║   ██║██║  ██║█████╗"
echo "██║╚██╗██║██╔══╝  ██║   ██║██║╚██╗██║██║   ██║██║  ██║██╔══╝"
echo "██║ ╚████║███████╗╚██████╔╝██║ ╚████║╚██████╔╝██████╔╝███████╗"
echo "╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝"
echo "${normal}"
echo "${white}  — powered by https://NeoNode.cc${normal}"
echo "$separator"

# Аптайм и нагрузка
uptime_str=$(uptime -p)
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)

# CPU
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8 "%"}')

# RAM
mem_data=$(free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}')

# Disk
disk=$(df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}')

# Сеть
traffic=$(vnstat --oneline 2>/dev/null | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
[ -z "$traffic" ] && traffic="vnstat not available"

# IP
ip_local=$(hostname -I | awk '{print $1}')
ip_public=$(curl -s ifconfig.me || echo "n/a")
ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$ip6" ] && ip6="n/a"

# CrowdSec
crowdsec=$(crowdsec-cli bouncers list 2>/dev/null | grep -v NAME | awk '{print $1 ": " $2}' | paste -sd ', ')
[ -z "$crowdsec" ] && crowdsec="${red}Not connected${normal}" || crowdsec="${green}${crowdsec}${normal}"

# Docker
if command -v docker &>/dev/null; then
    docker_total=$(docker ps -a -q | wc -l)
    docker_running=$(docker ps -q | wc -l)
    docker_stopped=$((docker_total - docker_running))
    docker_msg="${docker_running} running / ${docker_stopped} stopped"
else
    docker_msg="Not installed"
fi

# SSH
ssh_users=$(who | wc -l)
ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)

# Updates
updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
update_msg="${updates} package(s) can be updated"

# Вывод
printf "${bold}🧠 Uptime:        ${normal} %s\n" "$uptime_str"
printf "${bold}🧮 Load Average:  ${normal} %s\n" "$loadavg"
printf "${bold}⚙️  CPU Usage:     ${normal} %s\n" "$cpu_usage"
printf "${bold}💾 RAM Usage:     ${normal} %s\n" "$mem_data"
printf "${bold}💽 Disk Usage:    ${normal} %s\n" "$disk"
printf "${bold}📡 Net Traffic:   ${normal} %s\n" "$traffic"
printf "${bold}🔐 CrowdSec:      ${normal} %b\n" "$crowdsec"
printf "${bold}🐳 Docker:        ${normal} %s\n" "$docker_msg"
printf "${bold}👥 SSH Sessions:  ${normal} %s\n" "$ssh_users"
printf "${bold}🔗 SSH IPs:       ${normal} %s\n" "$ssh_ips"
printf "${bold}🌐 IP Address:    ${normal} Local: $ip_local | Public: $ip_public\n"
printf "${bold}🌍 IPv6 Address:   ${normal} $ip6\n"
printf "${bold}⬆️  Updates:       ${normal} $update_msg\n"
echo "$separator"
echo ""
EOF

# Предпросмотр
echo "===================================================="
echo "📋 Предпросмотр скрипта MOTD (NeoNode Dashboard):"
echo "===================================================="
echo "$DASHBOARD_CONTENT"
echo "===================================================="
read -p '❓ Установить этот скрипт? [y/N]: ' confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
    echo "$DASHBOARD_CONTENT" > "$DASHBOARD_FILE"
    chmod +x "$DASHBOARD_FILE"
    echo ""
    echo "✅ Скрипт установлен: $DASHBOARD_FILE"
    echo "Следующий вход по SSH покажет обновлённый MOTD."
else
    echo "❌ Установка отменена."
fi
