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
done

if [ "$INSTALL_USER_MODE" = true ]; then
    DASHBOARD_FILE="$HOME/.config/neonode/99-dashboard"
    MOTD_CONFIG_TOOL="$HOME/.local/bin/motd-config"
    CONFIG_GLOBAL="$HOME/.motdrc"
    mkdir -p "$(dirname "$DASHBOARD_FILE")" "$(dirname "$MOTD_CONFIG_TOOL")"
fi

# === Функция: Установка CLI утилиты motd-config ===
install_motd_config() {
    echo "📥 Установка CLI утилиты motd-config в $MOTD_CONFIG_TOOL"
    cat > "$MOTD_CONFIG_TOOL" << 'EOF'
#!/bin/bash

CONFIG_GLOBAL="/etc/motdrc"
CONFIG_USER="$HOME/.motdrc"
TARGET_FILE="$CONFIG_GLOBAL"

[ ! -w "$CONFIG_GLOBAL" ] && TARGET_FILE="$CONFIG_USER"

DASHBOARD_FILE_GLOBAL="/etc/update-motd.d/99-dashboard"
DASHBOARD_FILE_USER="$HOME/.config/neonode/99-dashboard"
TOOL_PATH_GLOBAL="/usr/local/bin/motd-config"
TOOL_PATH_USER="$HOME/.local/bin/motd-config"

OPTIONS=(
  SHOW_UPTIME
  SHOW_LOAD
  SHOW_CPU
  SHOW_RAM
  SHOW_DISK
  SHOW_NET
  SHOW_IP
  SHOW_DOCKER
  SHOW_SSH
  SHOW_SECURITY
  SHOW_UPDATES
  SHOW_AUTOUPDATES
)

print_menu() {
  echo "🔧 Настройка NeoNode MOTD"
  echo "1) Настроить отображаемые блоки"
  echo "2) Удалить MOTD-дашборд"
  echo "0) Выход"
}

configure_blocks() {
  echo "Выбери блоки для отображения (y/n):"
  for VAR in "${OPTIONS[@]}"; do
    read -p "$VAR (y/n) [Y]: " val
    case "${val,,}" in
      y|"") echo "$VAR=true" ;;
      n)    echo "$VAR=false" ;;
      *)    echo "$VAR=true" ;;
    esac
  done > "$TARGET_FILE"
  echo "✅ Настройки сохранены в $TARGET_FILE"
}

uninstall_dashboard() {
  echo "⚠️ Это удалит MOTD-дашборд, CLI и все настройки."
  read -p "Ты уверен? (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "🗑 Удаляем дашборд и конфиги..."

    sudo rm -f "$DASHBOARD_FILE_GLOBAL"
    rm -f "$DASHBOARD_FILE_USER"

    sudo rm -f "$TOOL_PATH_GLOBAL"
    rm -f "$TOOL_PATH_USER"

    sudo rm -f "$CONFIG_GLOBAL"
    rm -f "$CONFIG_USER"

    echo "✅ Всё удалено. MOTD вернётся к стандартному виду."
  else
    echo "❌ Отмена удаления."
  fi
}

while true; do
  print_menu
  read -p "Выбор: " choice
  case "$choice" in
    1) configure_blocks ;;
    2) uninstall_dashboard ;;
    0) exit ;;
    *) echo "❌ Неверный ввод" ;;
  esac
done 

echo "✅ Настройки сохранены в $TARGET_FILE"
EOF

    chmod +x "$MOTD_CONFIG_TOOL"
    echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
}

# === Функция: Создание глобального конфига ===
create_motd_global_config() {
    if [ ! -f "$CONFIG_GLOBAL" ]; then
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
        echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
    else
        echo "ℹ️ Глобальный конфиг уже существует: $CONFIG_GLOBAL"
    fi
}

# === Проверка способа запуска ===
if [ ! -t 0 ]; then
    echo "🌐 Скрипт запущен через pipe (wget/curl). Включен автоматический режим."
    FORCE_MODE=true
    echo "💡 Для интерактивного режима скачайте скрипт: wget https://famebloody.github.io/server/dashboard.sh && bash dashboard.sh"
    echo ""
fi

# === Проверка прав ===
if [ "$EUID" -ne 0 ] && [ "$INSTALL_USER_MODE" = false ]; then
    echo "❌ Пожалуйста, запусти от root или с флагом --not-root"
    exit 1
fi

TMP_FILE=$(mktemp)

# === Проверка зависимостей для всех пользователей ===
echo "🔍 Проверка необходимых утилит..."
MISSING=()
OPTIONAL_MISSING=()

# Обязательные утилиты
for CMD in curl hostname awk grep cut uname df free uptime; do
    if ! command -v "$CMD" &>/dev/null; then
        MISSING+=("$CMD")
    fi
done

# Опциональные утилиты (не критичные)
for CMD in top ip vnstat; do
    if ! command -v "$CMD" &>/dev/null; then
        OPTIONAL_MISSING+=("$CMD")
    fi
done

# Проверяем критичные утилиты
if (( ${#MISSING[@]} )); then
    echo "❌ Не хватает обязательных утилит: ${MISSING[*]}"
    echo "🛠 Установите их командой:"
    if [ "$EUID" -eq 0 ]; then
        echo "    apt update && apt install curl coreutils net-tools procps iproute2 -y"
    else
        echo "    sudo apt update && sudo apt install curl coreutils net-tools procps iproute2 -y"
    fi
    echo "🔁 После этого снова запустите установку."
    exit 1
fi

# Предупреждаем об опциональных утилитах
if (( ${#OPTIONAL_MISSING[@]} )); then
    echo "⚠️ Отсутствуют опциональные утилиты: ${OPTIONAL_MISSING[*]}"
    echo "💡 Для полной функциональности рекомендуется установить:"
    if [ "$EUID" -eq 0 ]; then
        echo "    apt install vnstat sysstat iproute2 -y"
    else
        echo "    sudo apt install vnstat sysstat iproute2 -y"
    fi
    echo "📝 Скрипт будет работать без них, но с ограниченной функциональностью."
    
    # Предлагаем автоматическую установку
    if [ "$FORCE_MODE" = false ] && [ -t 0 ]; then
        read -p "🤖 Установить опциональные пакеты автоматически? [y/N]: " install_optional < /dev/tty
        if [[ "$install_optional" =~ ^[Yy]$ ]]; then
            install_optional="y"
        fi
    elif [ "$FORCE_MODE" = true ]; then
        echo "🤖 Автоматическая установка опциональных пакетов в pipe-режиме..."
        install_optional="y"
    fi
    
    if [[ "$install_optional" =~ ^[Yy]$ ]]; then
            echo "📦 Устанавливаем опциональные пакеты..."
            if [ "$EUID" -eq 0 ]; then
                apt update >/dev/null 2>&1
                apt install vnstat sysstat iproute2 -y
            else
                sudo apt update >/dev/null 2>&1
                sudo apt install vnstat sysstat iproute2 -y
            fi
            
            # Инициализируем vnstat если установлен
            if command -v vnstat >/dev/null 2>&1; then
                echo "🔧 Инициализируем vnstat..."
                # Определяем основной сетевой интерфейс
                MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
                if [ -n "$MAIN_IF" ]; then
                    if [ "$EUID" -eq 0 ]; then
                        vnstat -i "$MAIN_IF" --create >/dev/null 2>&1
                        systemctl enable vnstat >/dev/null 2>&1
                        systemctl start vnstat >/dev/null 2>&1
                    else
                        sudo vnstat -i "$MAIN_IF" --create >/dev/null 2>&1
                        sudo systemctl enable vnstat >/dev/null 2>&1
                        sudo systemctl start vnstat >/dev/null 2>&1
                    fi
                    echo "✅ vnstat инициализирован для интерфейса $MAIN_IF"
                fi
            fi
        fi
    fi
    echo ""
fi

# === Создание dashboard-файла ===
if [ "$INSTALL_USER_MODE" = false ]; then
    mkdir -p /etc/update-motd.d
fi

cat > "$TMP_FILE" << 'EOF'
#!/bin/bash

# ОПТИМИЗАЦИЯ: Проверка на быстрое отключение MOTD
if [ -f "/tmp/.motd_disabled" ] || [ "$SSH_CLIENT_IP" = "DISABLED" ]; then
    exit 0
fi

# ОПТИМИЗАЦИЯ: Таймаут для всех операций
exec_with_timeout() {
    timeout 3 "$@" 2>/dev/null || echo "timeout"
}

CURRENT_VERSION="2025.05.09"

# ОПТИМИЗАЦИЯ: Проверка обновлений только раз в час
UPDATE_CHECK_FILE="/tmp/.motd_update_check"
if [ ! -f "$UPDATE_CHECK_FILE" ] || [ $(($(date +%s) - $(stat -c %Y "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0))) -gt 3600 ]; then
    REMOTE_URL="https://dignezzz.github.io/server/dashboard.sh"
    REMOTE_VERSION=$(exec_with_timeout curl -s --connect-timeout 2 "$REMOTE_URL" | grep '^CURRENT_VERSION=' | cut -d= -f2 | tr -d '"')
    
    if [ -n "$REMOTE_VERSION" ] && [ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]; then
        echo "⚠️ Доступна новая версия MOTD-дашборда: $REMOTE_VERSION (текущая: $CURRENT_VERSION)"
        echo "💡 Обновление: bash <(wget -qO- $REMOTE_URL) --force"
        echo ""
    fi
    
    # Создаем файл отметки времени
    touch "$UPDATE_CHECK_FILE" 2>/dev/null
fi

ok="✅"
fail="❌"
warn="⚠️"
separator="─~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

CONFIG_GLOBAL="/etc/motdrc"
CONFIG_USER="$HOME/.motdrc"
[ -f "$CONFIG_GLOBAL" ] && source "$CONFIG_GLOBAL"
[ -f "$CONFIG_USER" ] && source "$CONFIG_USER"

# Значения по умолчанию
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

# ОПТИМИЗАЦИЯ: Кэшируем данные на 30 секунд
CACHE_FILE="/tmp/.motd_cache"
CACHE_TIME=30

if [ -f "$CACHE_FILE" ] && [ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))) -lt $CACHE_TIME ]; then
    source "$CACHE_FILE"
else
    # Собираем данные только если кэш устарел
    uptime_str=$(exec_with_timeout uptime -p || echo "uptime unavailable")
    loadavg=$(exec_with_timeout cat /proc/loadavg | cut -d ' ' -f1-3 || echo "load unavailable")
    
    # CPU usage с проверкой наличия top
    if command -v top >/dev/null 2>&1; then
        cpu_usage=$(exec_with_timeout top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8 "%"}' | head -1)
        [ -z "$cpu_usage" ] && cpu_usage="n/a"
    else
        cpu_usage="top not available"
    fi
    
    mem_data=$(exec_with_timeout free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}' || echo "memory info unavailable")
    
    disk_used=$(exec_with_timeout df -h / | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
    disk_line=$(exec_with_timeout df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}' || echo "disk info unavailable")
    
    if [ "$disk_used" -ge 95 ] 2>/dev/null; then
        disk_status="$fail $disk_line [CRITICAL: Free up space immediately!]"
    elif [ "$disk_used" -ge 85 ] 2>/dev/null; then
        disk_status="$warn $disk_line [Warning: High usage]"
    else
        disk_status="$ok $disk_line"
    fi

    # ОПТИМИЗАЦИЯ: vnstat с проверкой установки и инициализации
    if command -v vnstat >/dev/null 2>&1; then
        # Проверяем, инициализирован ли vnstat
        if vnstat -i eth0 --json >/dev/null 2>&1 || vnstat -i ens3 --json >/dev/null 2>&1; then
            traffic=$(exec_with_timeout vnstat --oneline | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
            [ -z "$traffic" ] && traffic="vnstat: no data yet"
        else
            traffic="vnstat: not initialized (run: vnstat -i eth0 or similar)"
        fi
    else
        traffic="vnstat not installed"
    fi
    
    ip_local=$(exec_with_timeout hostname -I | awk '{print $1}' || echo "n/a")
    
    # ОПТИМИЗАЦИЯ: Публичный IP с коротким таймаутом
    ip_public=$(exec_with_timeout curl -s --connect-timeout 1 --max-time 2 ifconfig.me || echo "n/a")
    
    # IPv6 с проверкой наличия ip команды
    if command -v ip >/dev/null 2>&1; then
        ip6=$(exec_with_timeout ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
    else
        ip6="ip command not available"
    fi
    [ -z "$ip6" ] && ip6="n/a"

    # Docker информация с проверкой доступности
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker_total=$(exec_with_timeout docker ps -a -q | wc -l)
        docker_running=$(exec_with_timeout docker ps -q | wc -l)
        docker_stopped=$((docker_total - docker_running))
        docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
        
        bad_containers=$(exec_with_timeout docker ps -a --filter "status=exited" --filter "status=restarting" --format '⛔ {{.Names}} ({{.Status}})' | head -3)
        if [ -n "$bad_containers" ]; then
            docker_msg="$fail Issues: $docker_running running / $docker_stopped stopped"
            docker_msg_extra=$(echo "$bad_containers" | sed 's/^/                    /')
        fi
    else
        docker_msg="$warn not available"
    fi

    ssh_users=$(exec_with_timeout who | wc -l)
    ssh_ips=$(exec_with_timeout who | awk '{print $5}' | tr -d '()' | sort | uniq | paste -sd ', ' -)

    # Безопасность с проверками
    if command -v fail2ban-client >/dev/null 2>&1 && exec_with_timeout fail2ban-client status >/dev/null 2>&1; then
        fail2ban_status="$ok active"
    else
        fail2ban_status="$fail not available"
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(exec_with_timeout ufw status | grep -i "Status" | awk '{print $2}')
        if [[ "$ufw_status" == "active" ]]; then
            ufw_status="$ok enabled"
        else
            ufw_status="$fail disabled"
        fi
    else
        ufw_status="$fail not installed"
    fi

    if exec_with_timeout systemctl is-active crowdsec >/dev/null 2>&1; then
        crowdsec_status="$ok active"
    else
        crowdsec_status="$fail not running"
    fi

    # SSH конфигурация
    ssh_port=$(grep -Ei '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)
    [ -z "$ssh_port" ] && ssh_port=22
    [ "$ssh_port" != "22" ] && ssh_port_status="$ok non-standard port ($ssh_port)" || ssh_port_status="$warn default port (22)"

    permit_root=$(exec_with_timeout sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
    case "$permit_root" in
        yes) root_login_status="$fail enabled" ;;
        no) root_login_status="$ok disabled" ;;
        *) root_login_status="$warn limited ($permit_root)" ;;
    esac

    password_auth=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ "$password_auth" != "yes" ] && password_auth_status="$ok disabled" || password_auth_status="$fail enabled"

    # ОПТИМИЗАЦИЯ: Проверка обновлений с таймаутом
    updates=$(exec_with_timeout apt list --upgradable 2>/dev/null | grep -v "Listing" | wc -l)
    update_msg="${updates} package(s) can be updated"

    # Автообновления
    auto_update_status=""
    if dpkg -s unattended-upgrades >/dev/null 2>&1 && command -v unattended-upgrade >/dev/null 2>&1; then
        if grep -q 'Unattended-Upgrade "1";' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; then
            if exec_with_timeout systemctl is-enabled apt-daily.timer >/dev/null 2>&1 && exec_with_timeout systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1; then
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

    # Сохраняем в кэш
    cat > "$CACHE_FILE" << CACHE_EOF
uptime_str="$uptime_str"
loadavg="$loadavg"
cpu_usage="$cpu_usage"
mem_data="$mem_data"
disk_status="$disk_status"
traffic="$traffic"
ip_local="$ip_local"
ip_public="$ip_public"
ip6="$ip6"
docker_msg="$docker_msg"
docker_msg_extra="$docker_msg_extra"
ssh_users="$ssh_users"
ssh_ips="$ssh_ips"
fail2ban_status="$fail2ban_status"
ufw_status="$ufw_status"
crowdsec_status="$crowdsec_status"
ssh_port_status="$ssh_port_status"
root_login_status="$root_login_status"
password_auth_status="$password_auth_status"
update_msg="$update_msg"
auto_update_status="$auto_update_status"
CACHE_EOF
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
      echo " ~~~~~~ ↓↓↓ Security Block ↓↓↓ ~~~~~~"
      print_row "Fail2ban" "$fail2ban_status"
      print_row "CrowdSec" "$crowdsec_status"
      print_row "UFW Firewall" "$ufw_status"
      print_row "SSH Port" "$ssh_port_status"
      print_row "Root Login" "$root_login_status"
      print_row "Password Auth" "$password_auth_status"
      print_row "SSH Sessions" "$ssh_users"
      print_row "SSH IPs" "$ssh_ips"
      echo " ~~~~~~ ↑↑↑ Security Block ↑↑↑ ~~~~~~"
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

echo ""
printf " %-20s : %s\n" "Dashboard Ver" "$CURRENT_VERSION"
echo "$separator"
printf " %-20s : %s\n" "Config tool" "motd-config"
EOF

clear
echo "===================================================="
echo "📋 Предпросмотр NeoNode MOTD (оптимизированная версия):"
echo "===================================================="
bash "$TMP_FILE"
echo "===================================================="

if [ "$FORCE_MODE" = true ]; then
    echo "⚙️ Автоматическая установка без подтверждения (--force)"
    mv "$TMP_FILE" "$DASHBOARD_FILE"
    if [ "$INSTALL_USER_MODE" = false ]; then
        chmod +x "$DASHBOARD_FILE"
    fi
    install_motd_config
    create_motd_global_config
    echo "✅ Установлен оптимизированный дашборд: $DASHBOARD_FILE"
    echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
    echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
    echo ""
    echo "🚀 ОПТИМИЗАЦИИ:"
    echo "   • Кэширование данных на 30 секунд"
    echo "   • Таймауты для всех команд (3 сек)"
    echo "   • Проверка обновлений раз в час"
    echo "   • Быстрое отключение через /tmp/.motd_disabled"
    echo ""
    echo "👉 Для настройки отображения блоков — выполни: motd-config"
    echo "👉 Для отключения MOTD: touch /tmp/.motd_disabled"
    echo "👉 Обновлённый MOTD появится при следующем входе"

else
    echo "Будет выполнена установка оптимизированного набора:"
    echo "👉 Будет установлен дашборд: $DASHBOARD_FILE"
    echo "👉 Будет установлена CLI утилита: $MOTD_CONFIG_TOOL"
    echo "👉 Будет создан глобальный конфиг: $CONFIG_GLOBAL"
    echo "👉 Будут отключены все остальные скрипты в папке /etc/update-motd.d/"
    echo ""
    echo "🚀 ОПТИМИЗАЦИИ:"
    echo "   • Кэширование данных на 30 секунд"
    echo "   • Таймауты для всех команд (3 сек)"
    echo "   • Проверка обновлений раз в час"
    echo "   • Быстрое отключение через /tmp/.motd_disabled"
    echo ""
    
    # Проверяем, есть ли интерактивный терминал
    if [ -t 0 ]; then
        read -p '❓ Установить этот оптимизированный MOTD-дэшборд? [y/N]: ' confirm < /dev/tty
    else
        echo "🤖 Автоматическая установка в pipe-режиме..."
        confirm="y"
    fi
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mv "$TMP_FILE" "$DASHBOARD_FILE"
        if [ "$INSTALL_USER_MODE" = false ]; then
            chmod +x "$DASHBOARD_FILE"
            find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \;
        fi
        install_motd_config
        create_motd_global_config
        
        echo "✅ Установлен оптимизированный дашборд: $DASHBOARD_FILE"
        echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
        echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
        echo ""
        echo "👉 Для настройки отображения блоков — выполни: motd-config"
        echo "👉 Для отключения MOTD: touch /tmp/.motd_disabled"
        echo "👉 Обновлённый MOTD появится при следующем входе"
    else
        echo "❌ Установка отменена."
        rm -f "$TMP_FILE"
    fi
fi