#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

BACKUP_DIR="/etc/mtu_backups"
BACKUP_FILE="$BACKUP_DIR/mtu_backup_$(date +%F_%T).conf"
CURRENT_CONFIG="/tmp/current_mtu.conf"
LANG_CURRENT="ru"

msg_ru() {
    case $1 in
        "error_root") echo "Ошибка: Скрипт должен быть запущен с правами root (sudo)." ;;
        "backup_saved") echo "Текущая конфигурация сохранена в $BACKUP_FILE" ;;
        "current_mtu") echo "Текущие значения MTU:" ;;
        "rollback") echo "Откат изменений из последнего бэкапа..." ;;
        "mtu_restored") echo "Восстановлен MTU $2 для $3" ;;
        "no_backup") echo "Бэкап не найден! Откат невозможен." ;;
        "set_mtu") echo "Установка MTU $2 для $3..." ;;
        "mtu_set_success") echo "MTU успешно установлен на $2" ;;
        "mtu_set_error") echo "Ошибка установки MTU!" ;;
        "invalid_mtu") echo "Недопустимое значение MTU! Должно быть от 576 до 1500." ;;
        "invalid_interface") echo "Неверный выбор интерфейса!" ;;
        "select_interface") echo "Доступные сетевые интерфейсы:" ;;
        "choose_interface") echo "Выберите номер интерфейса: " ;;
        "selected_interface") echo "Выбран интерфейс: $2" ;;
        "enter_mtu") echo "Введите MTU (576-1500): " ;;
        "choose_preset") echo "Выберите пресет MTU: 1=1500, 2=1492, 3=1350, 4=1280" ;;
        "invalid_preset") echo "Неверный пресет! Используйте 1-4." ;;
        "menu_title") echo "=== Управление MTU ===" ;;
        "menu_show_mtu") echo "1) Показать текущие значения MTU" ;;
        "menu_set_mtu") echo "2) Установить MTU вручную" ;;
        "menu_preset") echo "3) Выбрать пресет MTU" ;;
        "menu_rollback") echo "4) Откатить изменения" ;;
        "menu_exit") echo "5) Выход" ;;
        "choose_action") echo "Выберите действие (1-5): " ;;
        "invalid_choice") echo "Неверный выбор!" ;;
        "exit") echo "Выход." ;;
        "forum") echo "Посетите мой форум: openode.xyz" ;;
        "blog") echo "Посетите мой блог: neonode.cc" ;;
        "intro_question") echo "Зачем вам этот скрипт? Есть ли у вас проблемы с работой (например, с нодами на Marzban)?" ;;
        "adapt_mtu") echo "Нужно ли адаптировать MTU для туннеля/VPN/прокси? (да/нет): " ;;
    esac
}

msg_en() {
    case $1 in
        "error_root") echo "Error: Script must be run as root (sudo)." ;;
        "backup_saved") echo "Current configuration saved to $BACKUP_FILE" ;;
        "current_mtu") echo "Current MTU values:" ;;
        "rollback") echo "Rolling back changes from the last backup..." ;;
        "mtu_restored") echo "Restored MTU $2 for $3" ;;
        "no_backup") echo "Backup not found! Rollback impossible." ;;
        "set_mtu") echo "Setting MTU $2 for $3..." ;;
        "mtu_set_success") echo "MTU successfully set to $2" ;;
        "mtu_set_error") echo "Error setting MTU!" ;;
        "invalid_mtu") echo "Invalid MTU value! Must be between 576 and 1500." ;;
        "invalid_interface") echo "Invalid interface choice!" ;;
        "select_interface") echo "Available network interfaces:" ;;
        "choose_interface") echo "Choose interface number: " ;;
        "selected_interface") echo "Selected interface: $2" ;;
        "enter_mtu") echo "Enter MTU (576-1500): " ;;
        "choose_preset") echo "Choose MTU preset: 1=1500, 2=1492, 3=1350, 4=1280" ;;
        "invalid_preset") echo "Invalid preset! Use 1-4." ;;
        "menu_title") echo "=== MTU Management ===" ;;
        "menu_show_mtu") echo "1) Show current MTU values" ;;
        "menu_set_mtu") echo "2) Set MTU manually" ;;
        "menu_preset") echo "3) Choose MTU preset" ;;
        "menu_rollback") echo "4) Rollback changes" ;;
        "menu_exit") echo "5) Exit" ;;
        "choose_action") echo "Choose action (1-5): " ;;
        "invalid_choice") echo "Invalid choice!" ;;
        "exit") echo "Exiting." ;;
        "forum") echo "Visit my forum: openode.xyz" ;;
        "blog") echo "Visit my blog: neonode.cc" ;;
        "intro_question") echo "Why do you need this script? Do you have any issues (e.g., with Marzban nodes)?" ;;
        "adapt_mtu") echo "Do you need to adapt MTU for tunnel/VPN/proxy? (yes/no): " ;;
    esac
}

msg() {
    if [ "$LANG_CURRENT" == "ru" ]; then
        msg_ru "$1" "$2" "$3"
    else
        msg_en "$1" "$2" "$3"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}$(msg "error_root")${NC}"
        exit 1
    fi
}

backup_mtu() {
    mkdir -p "$BACKUP_DIR"
    ip link > "$CURRENT_CONFIG"
    cp "$CURRENT_CONFIG" "$BACKUP_FILE"
    echo -e "${GREEN}$(msg "backup_saved")${NC}"
}

show_current_mtu() {
    echo -e "${BLUE}$(msg "current_mtu")${NC}"
    ip link | grep -E "mtu [0-9]+" | awk '{print $2 " " $3 " " $4}'
}

rollback_mtu() {
    if [ -f "$BACKUP_FILE" ]; then
        echo -e "${BLUE}$(msg "rollback")${NC}"
        while read -r line; do
            interface=$(echo "$line" | awk '{print $2}' | sed 's/://')
            mtu=$(echo "$line" | grep -o "mtu [0-9]*" | awk '{print $2}')
            if [ -n "$interface" ] && [ -n "$mtu" ]; then
                ip link set dev "$interface" mtu "$mtu" 2>/dev/null
                echo -e "${GREEN}$(msg "mtu_restored" "$mtu" "$interface")${NC}"
            fi
        done < "$BACKUP_FILE"
        echo -e "${GREEN}$(msg "forum")${NC}"
        echo -e "${GREEN}$(msg "blog")${NC}"
    else
        echo -e "${RED}$(msg "no_backup")${NC}"
    fi
}

apply_mtu() {
    local mtu=$1
    echo -e "${BLUE}$(msg "set_mtu" "$mtu" "$INTERFACE")${NC}"
    ip link set dev "$INTERFACE" mtu "$mtu" && \
    { echo -e "${GREEN}$(msg "mtu_set_success" "$mtu")${NC}"; echo -e "${GREEN}$(msg "forum")${NC}"; echo -e "${GREEN}$(msg "blog")${NC}"; } || \
    { echo -e "${RED}$(msg "mtu_set_error")${NC}"; exit 1; }
}

interactive_start() {
    echo -e "${BLUE}$(msg "intro_question")${NC}"
    read -p "> " user_input
    echo -e "${BLUE}$(msg "adapt_mtu")${NC}"
    read -p "> " adapt_mtu
    if [ "$adapt_mtu" == "да" ] || [ "$adapt_mtu" == "yes" ]; then
        echo -e "${GREEN}Рекомендуется использовать MTU 1350 для туннелей/VPN.${NC}"
    else
        echo -e "${GREEN}Вы можете использовать стандартное MTU 1500.${NC}"
    fi
    echo -e "${GREEN}$(msg "forum")${NC}"
    echo -e "${GREEN}$(msg "blog")${NC}"
}

while getopts "i:m:p:rl:" opt; do
    case $opt in
        i) INTERFACE=$OPTARG ;;
        m) MTU=$OPTARG ;;
        p) PRESET=$OPTARG ;;
        r) ROLLBACK=true ;;
        l) LANG_CURRENT=$OPTARG ;;
        *) echo -e "${RED}Неверный параметр!${NC}"; exit 1 ;;
    esac
done

if [ -n "$ROLLBACK" ]; then
    check_root
    rollback_mtu
elif [ -n "$INTERFACE" ] && [ -n "$MTU" ]; then
    check_root
    if [[ "$MTU" =~ ^[0-9]+$ ]] && [ "$MTU" -ge 576 ] && [ "$MTU" -le 1500 ]; then
        backup_mtu
        apply_mtu "$MTU"
    else
        echo -e "${RED}$(msg "invalid_mtu")${NC}"
        exit 1
    fi
elif [ -n "$INTERFACE" ] && [ -n "$PRESET" ]; then
    check_root
    case $PRESET in
        1) MTU=1500 ;;
        2) MTU=1492 ;;
        3) MTU=1350 ;;
        4) MTU=1280 ;;
        *) echo -e "${RED}$(msg "invalid_preset")${NC}"; exit 1 ;;
    esac
    backup_mtu
    apply_mtu "$MTU"
else
    interactive_start
    check_root
    while true; do
        clear
        echo -e "${BLUE}=======================${NC}"
        echo -e "${BLUE}$(msg "menu_title")${NC}"
        echo -e "${BLUE}=======================${NC}"
        echo -e "${GREEN}$(msg "forum")${NC}"
        echo -e "${GREEN}$(msg "blog")${NC}"
        echo -e "${BLUE}-----------------------${NC}"
        echo "$(msg "menu_show_mtu")"
        echo "$(msg "menu_set_mtu")"
        echo "$(msg "menu_preset")"
        echo "$(msg "menu_rollback")"
        echo "$(msg "menu_exit")"
        echo -e "${BLUE}-----------------------${NC}"
        read -p "$(msg "choose_action")" action
        case $action in
            1) show_current_mtu; read -p "Нажмите Enter...";;
            2) echo -e "${BLUE}$(msg "select_interface")${NC}"
               ip link | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://' | nl -s ") "
               read -p "$(msg "choose_interface")" choice
               INTERFACE=$(ip link | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://' | sed -n "${choice}p")
               if [ -n "$INTERFACE" ]; then
                   backup_mtu
                   read -p "$(msg "enter_mtu")" custom_mtu
                   if [[ "$custom_mtu" =~ ^[0-9]+$ ]] && [ "$custom_mtu" -ge 576 ] && [ "$custom_mtu" -le 1500 ]; then
                       apply_mtu "$custom_mtu"
                   else
                       echo -e "${RED}$(msg "invalid_mtu")${NC}"
                   fi
               else
                   echo -e "${RED}$(msg "invalid_interface")${NC}"
               fi; read -p "Нажмите Enter...";;
            3) echo -e "${BLUE}$(msg "select_interface")${NC}"
               ip link | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://' | nl -s ") "
               read -p "$(msg "choose_interface")" choice
               INTERFACE=$(ip link | grep -E "^[0-9]+" | awk '{print $2}' | sed 's/://' | sed -n "${choice}p")
               if [ -n "$INTERFACE" ]; then
                   backup_mtu
                   echo "$(msg "choose_preset")"
                   read -p "Выберите пресет (1-4): " preset
                   case $preset in
                       1) apply_mtu 1500;;
                       2) apply_mtu 1492;;
                       3) apply_mtu 1350;;
                       4) apply_mtu 1280;;
                       *) echo -e "${RED}$(msg "invalid_preset")${NC}";;
                   esac
               else
                   echo -e "${RED}$(msg "invalid_interface")${NC}"
               fi; read -p "Нажмите Enter...";;
            4) rollback_mtu; read -p "Нажмите Enter...";;
            5) echo -e "${GREEN}$(msg "exit")${NC}"; exit 0;;
            *) echo -e "${RED}$(msg "invalid_choice")${NC}"; read -p "Нажмите Enter...";;
        esac
    done
fi
