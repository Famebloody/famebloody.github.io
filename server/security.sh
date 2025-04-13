#!/bin/bash

echo "Choose language / Выберите язык:"
echo "1) English"
echo "2) Русский"
read -rp "[1/2] (default 1): " lang_choice

lang_choice=${lang_choice:-1}

if [ "$lang_choice" = "2" ]; then
  MSG_WELCOME="Будут выполнены следующие изменения:\n- Отключение авторизации по паролю\n- Ограничение входа по SSH\n- Установка строгих прав на SSH\n\nПродолжить? [Y/n]"
  MSG_ERROR_KEY="Ошибка: файл authorized_keys пуст или отсутствует. Добавьте публичный ключ перед продолжением."
  MSG_BACKUP_CREATED="Создана резервная копия конфигурации SSH"
  MSG_SSH_RESTART_SUCCESS="SSH успешно перезапущен."
  MSG_SSH_RESTART_FAIL="Ошибка: Не удалось перезапустить SSH. Восстанавливаю исходный конфиг..."
  MSG_DONE="Настройки SSH успешно обновлены."
else
  MSG_WELCOME="The following changes will be applied:\n- Disable password authentication\n- SSH access restriction\n- Set strict permissions on SSH\n\nContinue? [Y/n]"
  MSG_ERROR_KEY="Error: authorized_keys file is empty or missing. Please add a public key before continuing."
  MSG_BACKUP_CREATED="Backup of SSH configuration created"
  MSG_SSH_RESTART_SUCCESS="SSH successfully restarted."
  MSG_SSH_RESTART_FAIL="Error: Could not restart SSH. Restoring original config..."
  MSG_DONE="SSH settings successfully updated."
fi

read -rp "$MSG_WELCOME " answer
answer=${answer:-Y}
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  exit 0
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"
SSHD_CONFIG_BACKUP="${SSHD_CONFIG}.bak_$(date +%Y%m%d_%H%M%S)"

if [ ! -s "$AUTHORIZED_KEYS" ]; then
  echo "$MSG_ERROR_KEY"
  exit 1
fi

cp "$SSHD_CONFIG" "$SSHD_CONFIG_BACKUP"
echo "$MSG_BACKUP_CREATED: $SSHD_CONFIG_BACKUP"

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
  echo "$MSG_SSH_RESTART_SUCCESS"
else
  echo "$MSG_SSH_RESTART_FAIL"
  cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG"
  systemctl restart ssh.service || systemctl restart sshd.service
  exit 1
fi

echo "$MSG_DONE"
