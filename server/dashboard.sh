
#!/bin/bash

DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"

# Временный файл для предпросмотра
TMP_FILE=$(mktemp)

/bin/cat > "$TMP_FILE" << 'EOF'
#!/bin/bash
bold=$(tput bold)
normal=$(tput sgr0)
blue=$(tput setaf 4)
green=$(tput setaf 2)
red=$(tput setaf 1)
yellow=$(tput setaf 3)
cyan=$(tput setaf 6)
white=$(tput setaf 7)
separator="${blue}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${normal}"

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

uptime_str=$(uptime -p)
loadavg=$(cut -d ' ' -f1-3 /proc/loadavg)
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8 "%"}')
mem_data=$(free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}')
disk=$(df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}')
traffic=$(command -v vnstat &>/dev/null && vnstat --oneline | awk -F\; '{print $10 " ↓ / " $11 " ↑"}' || echo "vnstat not available")
ip_local=$(hostname -I | awk '{print $1}')
ip_public=$(curl -s ifconfig.me || echo "n/a")
ip6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$ip6" ] && ip6="n/a"
if command -v crowdsec-cli &>/dev/null; then
    crowdsec=$(crowdsec-cli bouncers list 2>/dev/null | grep -v NAME | awk '{print $1 ": " $2}' | paste -sd ', ')
    [ -z "$crowdsec" ] && crowdsec="${red}Not connected${normal}" || crowdsec="${green}${crowdsec}${normal}"
else
    crowdsec="${yellow}not installed${normal}"
fi
if command -v docker &>/dev/null; then
    docker_total=$(docker ps -a -q | wc -l)
    docker_running=$(docker ps -q | wc -l)
    docker_stopped=$((docker_total - docker_running))
    docker_msg="${docker_running} running / ${docker_stopped} stopped"
else
    docker_msg="${yellow}not installed${normal}"
fi
ssh_users=$(who | wc -l)
ssh_ips=$(who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)
updates=$(apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
update_msg="${updates} package(s) can be updated"

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

# Предпросмотр в реальном времени
chmod +x "$TMP_FILE"
clear
echo "===================================================="
echo "📋 Предпросмотр NeoNode MOTD (реальный вывод):"
echo "===================================================="
bash "$TMP_FILE"
echo "===================================================="
read -p '❓ Установить этот MOTD-дашборд? [y/N]: ' confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
    mv "$TMP_FILE" "$DASHBOARD_FILE"
    chmod +x "$DASHBOARD_FILE"
    find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
    echo "✅ Установлено: $DASHBOARD_FILE"
else
    echo "❌ Установка отменена."
    rm -f "$TMP_FILE"
fi
