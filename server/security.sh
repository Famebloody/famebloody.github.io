#!/bin/bash

# Color definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

# Language selection
echo -e "${CYAN}Choose language / Выберите язык:${NC}"
echo "1) English"
echo "2) Русский"
read -rp "[1/2] (default 1): " lang_choice

lang_choice=${lang_choice:-1}

if [ "$lang_choice" = "2" ]; then
  MSG_WELCOME="${YELLOW}Будут выполнены следующие изменения:${NC}\n- ${RED}Отключение авторизации по паролю${NC}\n- ${RED}Ограничение входа по SSH${NC}\n- ${RED}Установка строгих прав на SSH${NC}\n\n${GREEN}Продолжить?${NC} [Y/n]"
  MSG_ERROR_KEY="${RED}Ошибка:${NC} файл authorized_keys пуст или отсутствует. Добавьте публичный ключ перед продолжением."
  MSG_BACKUP_CREATED="${GREEN}Создана резервная копия конфигурации SSH:${NC}"
  MSG_SSH_RESTART_SUCCESS="${GREEN}SSH успешно перезапущен.${NC}"
  MSG_SSH_RESTART_FAIL="${RED}Ошибка:${NC} Не удалось перезапустить SSH. Восстанавливаю исходный конфиг..."
  MSG_DONE="${GREEN}Настройки SSH успешно обновлены.${NC}"
else
  MSG_WELCOME="${YELLOW}The following changes will be applied:${NC}\n- ${RED}Disable password authentication${NC}\n- ${RED}SSH access restriction${NC}\n- ${RED}Set strict permissions on SSH${NC}\n\n${GREEN}Continue?${NC} [Y/n]"
  MSG_ERROR_KEY="${RED}Error:${NC} authorized_keys file is empty or missing. Please add a public key before continuing."
  MSG_BACKUP_CREATED="${GREEN}Backup of SSH configuration created:${NC}"
  MSG_SSH_RESTART_SUCCESS="${GREEN}SSH successfully restarted.${NC}"
  MSG_SSH_RESTART_FAIL="${RED}Error:${NC} Could not restart SSH. Restoring original config..."
  MSG_DONE="${GREEN}SSH settings successfully updated.${NC}"
fi

read -rp -e "$MSG_WELCOME " answer
answer=${answer:-Y}
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo -e "${RED}Operation cancelled by user.${NC}"
  exit 0
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
SSHD_CONFIG_BACKUP="${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"

if [ ! -s "$AUTHORIZED_KEYS" ]; then
  echo -e "$MSG_ERROR_KEY"
  exit 1
fi

cp "$SSHD_CONFIG" "$SSHD_CONFIG_BACKUP"
echo -e "$MSG_BACKUP_CREATED ${BLUE}$SSHD_CONFIG_BACKUP${NC}"

add_config_if_missing() {
  PARAM_NAME=$(echo "$1" | awk '{print $1}')
  if grep -qE "^[#\\s]*${PARAM_NAME}\\s" "$SSHD_CONFIG"; then
    sed -i "s|^[#\\s]*${PARAM_NAME}\\s.*|$1|" "$SSHD_CONFIG"
  else
    echo "$1" >> "$SSHD_CONFIG"
  fi
}

add_config_if_missing "PubkeyAuthentication yes"
add_config_if_missing "AuthorizedKeysFile %h/.ssh/authorized_keys"
add_config_if_missing "RhostsRSAAuthentication no"
add_config_if_missing "HostbasedAuthentication no"
add_config_if_missing "PermitEmptyPasswords no"
add_config_if_missing "PasswordAuthentication no"
add_config_if_missing "PubkeyAcceptedAlgorithms +ssh-rsa"
add_config_if_missing "Protocol 2"
add_config_if_missing "LoginGraceTime 30s"
add_config_if_missing "MaxAuthTries 3"
add_config_if_missing "MaxSessions 2"
add_config_if_missing "AllowTcpForwarding no"
add_config_if_missing "X11Forwarding no"
add_config_if_missing "ClientAliveInterval 300"
add_config_if_missing "ClientAliveCountMax 0"

chmod 700 "$HOME/.ssh"
chmod 600 "$AUTHORIZED_KEYS"
chmod 600 "$SSHD_CONFIG"

if systemctl restart ssh.service || systemctl restart sshd.service; then
  echo -e "$MSG_SSH_RESTART_SUCCESS"
else
  echo -e "$MSG_SSH_RESTART_FAIL"
  cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG"
  systemctl restart ssh.service || systemctl restart sshd.service
  exit 1
fi

echo -e "$MSG_DONE"
