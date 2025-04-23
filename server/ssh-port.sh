#!/bin/bash

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local timestamp=$(date +%Y%m%d_%H%M%S)
        cp "$file" "${file}.backup_$timestamp"
        echo -e "\e[32mBackup created: ${file}.backup_$timestamp\e[0m"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "\e[31mPlease run the script as root (sudo).\e[0m"
        exit 1
    fi
}

detect_os() {
    os_name=$(lsb_release -is 2>/dev/null || grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    os_version=$(lsb_release -rs 2>/dev/null || grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    echo -e "\e[34mDetected system: $os_name $os_version\e[0m"
}

get_current_port() {
    grep -E '^Port[[:space:]]+[0-9]+' "$1" | awk '{print $2}' || echo "22"
}

change_port_in_config() {
    local config_file=$1
    local port=$2
    sed -i -E "s/^#?Port[[:space:]]+[0-9]+/Port $port/" "$config_file"
    echo -e "\e[32mPort was changed in the file: $config_file\e[0m"
    echo -e "\e[32mNew port: $port\e[0m"
}

is_port_in_use() {
    local port=$1
    ss -tuln | grep -q ":$port "
}

reload_ssh_services() {
    local version=$1
    if [ "$version" = "24.04" ]; then
        echo -e "\e[34mUsing socket-activated SSH on Ubuntu 24.04\e[0m"
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

# Main execution starts here
check_root
detect_os

SSHD_CONFIG="/etc/ssh/sshd_config"
SOCKET_FILE="/lib/systemd/system/ssh.socket"

os_version=$(lsb_release -rs 2>/dev/null || grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
current_port=$(get_current_port "$SSHD_CONFIG")
echo -e "\e[34mCurrent SSH port: $current_port\e[0m"

while true; do
    read -p "Enter a new port for SSH (1-65535): " new_port

    # Validate input
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "\e[31mInvalid port number. Must be between 1 and 65535.\e[0m"
        continue
    fi

    if [ "$new_port" = "$current_port" ]; then
        echo -e "\e[33mThe new port is the same as the current SSH port. No changes needed.\e[0m"
        exit 0
    fi

    if is_port_in_use "$new_port"; then
        echo -e "\e[31mPort $new_port is already in use. Please choose another port.\e[0m"
        continue
    fi

    break
done

backup_file "$SSHD_CONFIG"
change_port_in_config "$SSHD_CONFIG" "$new_port"

if [ "$os_version" = "24.04" ] && [ -f "$SOCKET_FILE" ]; then
    backup_file "$SOCKET_FILE"
    sed -i -E "s/ListenStream=\s*[0-9]+/ListenStream=$new_port/" "$SOCKET_FILE"
    echo -e "\e[32mUpdated ListenStream in: $SOCKET_FILE\e[0m"
fi

reload_ssh_services "$os_version"
status=$?

if [ $status -eq 0 ]; then
    echo -e "\e[32mSSH service restarted successfully.\e[0m"
else
    echo -e "\e[31mFailed to restart SSH service.\e[0m"
fi
