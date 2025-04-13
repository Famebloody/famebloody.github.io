#!/bin/bash

backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup_$(date +%Y%m%d_%H%M%S)"
        echo -e "\e[32mBackup created: ${file}.backup_$(date +%Y%m%d_%H%M%S)\e[0m"
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "\e[31mPlease run the script as root (sudo).\e[0m"
        exit 1
    fi
}

detect_os() {
    os_name=$(lsb_release -is 2>/dev/null || grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '\"')
    os_version=$(lsb_release -rs 2>/dev/null || grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '\"')
    echo -e "\e[34mDetected system: $os_name $os_version\e[0m"
}

get_current_port() {
    grep -Po '(?<=^Port )\d+' "$1" || echo "22"
}

change_port_in_config() {
    local config_file=$1
    local port=$2
    sed -i "s/^#\?Port .*/Port $port/" "$config_file"
    echo -e "\e[32mPort was changed in the file: $config_file\e[0m"
    echo -e "\e[32mNew port: $port\e[0m"
}

reload_ssh_service() {
    if command -v systemctl > /dev/null; then
        systemctl daemon-reload
        if ! systemctl restart ssh && ! systemctl restart sshd; then
            echo -e "\e[31mFailed to restart SSH service.\e[0m"
            exit 1
        fi
    else
        if ! service ssh restart && ! service sshd restart; then
            echo -e "\e[31mFailed to restart SSH service.\e[0m"
            exit 1
        fi
    fi
}

check_port_availability() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        echo -e "\e[31mError: Port $port is already in use by another process.\e[0m"
        exit 1
    fi
}

check_ssh_port() {
    local port=$1
    sleep 2
    if ss -tuln | grep -q ":$port "; then
        echo -e "\e[32mSSH is successfully running on port $port.\e[0m"
    else
        echo -e "\e[31mSSH is NOT running on port $port! Restoring previous configuration.\e[0m"
        return 1
    fi
}

prompt_for_port() {
    read -rp "Enter a new port for SSH (1-65535): " new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "\e[31mError: Port must be a number between 1 and 65535.\e[0m"
        exit 1
    fi

    check_port_availability "$new_port"
    echo "$new_port"
}

check_firewall_rules() {
    local new_port=$1
    local old_port=$2

    if command -v ufw > /dev/null; then
        ufw allow "$new_port"/tcp
        ufw delete allow "$old_port"/tcp
        ufw reload
        echo -e "\e[32mFirewall rules updated (UFW): Port $new_port allowed, Port $old_port removed.\e[0m"
    elif command -v iptables > /dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT
            iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null
            echo -e "\e[32mFirewall rules updated (iptables): Port $new_port allowed, Port $old_port removed.\e[0m"
        fi
    else
        echo -e "\e[31mNo firewall detected. Ensure port $new_port is open manually.\e[0m"
    fi
}

change_port() {
    local config_file="$1"
    local current_port=$(get_current_port "$config_file")
    echo -e "\e[33mCurrent SSH port: $current_port\e[0m"

    local new_port=$(prompt_for_port)

    backup_file "$config_file"
    change_port_in_config "$config_file" "$new_port"

    reload_ssh_service

    if ! check_ssh_port "$new_port"; then
        cp "${config_file}.backup"* "$config_file"
        reload_ssh_service
        exit 1
    fi

    echo -e "\e[32mSSH port successfully changed to $new_port.\e[0m"
    check_firewall_rules "$new_port" "$current_port"
}

main() {
    check_root
    detect_os

    if [[ "$os_name" == "Ubuntu" && "$os_version" == "24.04" ]]; then
        backup_file "/lib/systemd/system/ssh.socket"
        sed -i "s/^ListenStream=.*/ListenStream=$(prompt_for_port)/" "/lib/systemd/system/ssh.socket"
        change_port "/etc/ssh/sshd_config"
    else
        change_port "/etc/ssh/sshd_config"
    fi

    echo -e "\e[34m----------------------------------------------------\e[0m"
    echo -e "\e[32mCreated by DigneZzZ\e[0m"
    echo -e "\e[36mJoin my community: https://openode.xyz\e[0m"
}

main
