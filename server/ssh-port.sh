#!/bin/bash

log() {
    echo -e "$1"
    logger -t ssh-port-changer "$(echo -e "$1" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')"  # без цвета
}

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$file" "${file}.backup_$timestamp"
        log "\e[32mBackup created: ${file}.backup_$timestamp\e[0m"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log "\e[31mPlease run the script as root (sudo).\e[0m"
        exit 1
    fi
}

detect_os() {
    os_name=$(lsb_release -is 2>/dev/null || grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    os_version=$(lsb_release -rs 2>/dev/null || grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    log "\e[34mDetected system: $os_name $os_version\e[0m"
}

get_current_port() {
    grep -E '^Port[[:space:]]+[0-9]+' "$1" | awk '{print $2}' || echo "22"
}

ensure_port_directive_exists() {
    local file=$1
    if ! grep -qE '^\s*#?\s*Port\s+[0-9]+' "$file"; then
        echo "Port 22" >> "$file"
    fi
}

change_port_in_config() {
    local config_file=$1
    local port=$2
    sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port $port/" "$config_file"
    log "\e[32mPort was changed in the file: $config_file\e[0m"
    log "\e[32mNew port: $port\e[0m"
}

is_port_in_use() {
    local port=$1
    ss -tuln | grep -q ":$port "
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

reload_ssh_services() {
    local version=$1
    if [ "$version" = "24.04" ]; then
        log "\e[34mUsing socket-activated SSH on Ubuntu 24.04\e[0m"
        systemctl daemon-reexec
        systemctl daemon-reload
        systemctl restart ssh.socket
        systemctl restart ssh.service
    else
        if systemctl list-units --type=service | grep -q 'sshd.service'; then
            systemctl restart sshd.service
        elif systemctl list-units --type=service | grep -q 'ssh.service'; then
            systemctl restart ssh.service
        fi
    fi
}

test_port_reachable() {
    local port=$1
    log "\e[34mTesting SSH on port $port...\e[0m"
    if timeout 3 bash -c "</dev/tcp/127.0.0.1/$port" &>/dev/null; then
        log "\e[32mPort $port is reachable locally.\e[0m"
    else
        log "\e[33mWarning: Port $port is not reachable locally. Check firewall or SSH config.\e[0m"
    fi
}

configure_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q 'Status: active'; then
            if ! ufw status | grep -q "$1"; then
                log "\e[34mAdding SSH port $1 to UFW rules...\e[0m"
                ufw allow "$1"/tcp
                log "\e[32mPort $1 added to UFW rules.\e[0m"
            else
                log "\e[33mPort $1 already allowed in UFW.\e[0m"
            fi
        else
            log "\e[33mUFW is installed but not active. Skipping firewall rule.\e[0m"
        fi
    else
        log "\e[33mUFW is not installed. Skipping firewall rule.\e[0m"
    fi
}

remove_old_port_from_ufw() {
    local port=$1
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q 'Status: active'; then
            if ufw status | grep -q "$port"; then
                ufw delete allow "$port"/tcp
                log "\e[32mOld port $port removed from UFW.\e[0m"
            else
                log "\e[33mOld port $port was not in UFW rules.\e[0m"
            fi
        else
            log "\e[33mUFW is installed but not active. Cannot remove port $port.\e[0m"
        fi
    fi
}


# ---------------- MAIN ---------------- #

check_root
detect_os

SSHD_CONFIG="/etc/ssh/sshd_config"
SOCKET_FILE="/lib/systemd/system/ssh.socket"

AUTO_YES=0
NEW_PORT=""

# Флаги
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            AUTO_YES=1
            shift
            ;;
        --port)
            NEW_PORT="$2"
            shift 2
            ;;
        *)
            log "\e[31mUnknown option: $1\e[0m"
            exit 1
            ;;
    esac
done

current_port=$(get_current_port "$SSHD_CONFIG")
log "\e[34mCurrent SSH port: $current_port\e[0m"

if [ -z "$NEW_PORT" ] && [ "$AUTO_YES" -eq 0 ]; then
    while true; do
        read -p "Enter a new port for SSH (1-65535): " NEW_PORT
        if validate_port "$NEW_PORT"; then
            break
        else
            log "\e[31mInvalid port number. Must be between 1 and 65535.\e[0m"
        fi
    done
fi

# Проверки
if ! validate_port "$NEW_PORT"; then
    log "\e[31mInvalid or missing port. Use --port <1-65535>.\e[0m"
    exit 1
fi

if [ "$NEW_PORT" = "$current_port" ]; then
    log "\e[33mThe new port is the same as the current SSH port. No changes needed.\e[0m"
    exit 0
fi

if is_port_in_use "$NEW_PORT"; then
    log "\e[31mPort $NEW_PORT is already in use.\e[0m"
    exit 1
fi

backup_file "$SSHD_CONFIG"
ensure_port_directive_exists "$SSHD_CONFIG"
change_port_in_config "$SSHD_CONFIG" "$NEW_PORT"

if [ "$os_version" = "24.04" ] && [ -f "$SOCKET_FILE" ]; then
    backup_file "$SOCKET_FILE"
    sed -i -E "s/ListenStream=\s*[0-9]+/ListenStream=$NEW_PORT/" "$SOCKET_FILE"
    log "\e[32mUpdated ListenStream in: $SOCKET_FILE\e[0m"
fi

reload_ssh_services "$os_version"
status=$?

configure_ufw "$NEW_PORT"
if [ $status -eq 0 ]; then
    log "\e[32mSSH service restarted successfully.\e[0m"

    # Предложить удалить старый порт из UFW, если всё прошло успешно
    if [ "$AUTO_YES" -eq 0 ]; then
        read -p "Remove old SSH port $current_port from UFW? [y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            remove_old_port_from_ufw "$current_port"
        fi
    fi
else
    log "\e[31mFailed to restart SSH service.\e[0m"
    exit 1
fi


test_port_reachable "$NEW_PORT"
