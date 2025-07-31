#!/bin/bash

# ======================================================================
# MOTD Dashboard Management Script
# Версия: 2025.07.30 (Refactored)
# Автор: NeoNode.cc
# Описание: Установка, настройка и управление кастомным MOTD дашбордом
# ======================================================================

set -euo pipefail  # Строгий режим bash

# === ГЛОБАЛЬНЫЕ КОНСТАНТЫ ===
readonly SCRIPT_VERSION="2025.07.30-refactored"
readonly REMOTE_URL="https://famebloody.github.io/server/dashboard-refactored.sh"

# Пути по умолчанию (глобальная установка)
readonly DEFAULT_DASHBOARD_FILE="/etc/update-motd.d/99-dashboard"
readonly DEFAULT_CONFIG_GLOBAL="/etc/motdrc"
readonly DEFAULT_MOTD_CONFIG_TOOL="/usr/local/bin/motd-config"

# Пути для резервного копирования и логирования
readonly BACKUP_BASE_DIR="/var/backups/motd"
readonly LOG_FILE="/var/log/motd_custom.log"

# === ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===
DASHBOARD_FILE="$DEFAULT_DASHBOARD_FILE"
CONFIG_GLOBAL="$DEFAULT_CONFIG_GLOBAL"
MOTD_CONFIG_TOOL="$DEFAULT_MOTD_CONFIG_TOOL"

# Режимы работы
OPERATION_MODE="install"
FORCE_MODE=false
INSTALL_USER_MODE=false

# ======================================================================
# СИСТЕМА ЛОГИРОВАНИЯ
# ======================================================================

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="$LOG_FILE"
    
    # Создаем лог-файл если не существует
    if [[ ! -f "$log_file" ]] && [[ "$INSTALL_USER_MODE" == false ]]; then
        sudo touch "$log_file" 2>/dev/null || log_file="$HOME/.motd_install.log"
    elif [[ "$INSTALL_USER_MODE" == true ]]; then
        log_file="$HOME/.motd_install.log"
    fi
    
    # Записываем в лог
    echo "[$timestamp] [$level] $message" >> "$log_file" 2>/dev/null || true
    
    # Выводим в терминал
    case "$level" in
        "ERROR")   echo "❌ $message" ;;
        "WARNING") echo "⚠️ $message" ;;
        "INFO")    echo "ℹ️ $message" ;;
        *)         echo "$message" ;;
    esac
}

log_info() {
    log_message "INFO" "$1"
}

log_warning() {
    log_message "WARNING" "$1"
}

log_error() {
    log_message "ERROR" "$1"
}

# ======================================================================
# ОБРАБОТКА ОШИБОК
# ======================================================================

fatal_error() {
    local message="$1"
    local exit_code="${2:-1}"
    
    log_error "Критическая ошибка: $message"
    echo "💥 Установка прервана из-за критической ошибки."
    echo "📋 Подробности в лог-файле: $LOG_FILE"
    exit "$exit_code"
}

check_error() {
    local exit_code=$?
    local operation="$1"
    
    if [[ $exit_code -ne 0 ]]; then
        fatal_error "Операция '$operation' завершилась с ошибкой (код: $exit_code)" $exit_code
    fi
}

# Обработчик сигналов для корректного завершения
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Скрипт завершился с ошибкой (код: $exit_code)"
        
        # Удаляем временные файлы
        [[ -n "${TMP_FILE:-}" ]] && [[ -f "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null || true
    fi
    
    exit $exit_code
}

trap cleanup_on_exit EXIT

# ======================================================================
# ФУНКЦИИ ПОМОЩИ И КОНФИГУРАЦИИ
# ======================================================================

show_help() {
    cat << EOF
📋 MOTD Dashboard Management Script - Управление кастомным MOTD дашбордом

ИСПОЛЬЗОВАНИЕ:
    bash dashboard.sh [ОПЦИИ]

ОПЦИИ:
    --install         Установить новый MOTD дашборд (по умолчанию)
    --restore         Восстановить оригинальные MOTD файлы из резервной копии
    --help            Показать эту справку

    --force           Автоматическая установка без интерактивных запросов
    --not-root        Установка в пользовательский режим (без root прав)

ПРИМЕРЫ:
    bash dashboard.sh                    # Установка с интерактивными запросами
    bash dashboard.sh --force            # Автоматическая установка
    bash dashboard.sh --restore          # Восстановление из резервной копии
    bash dashboard.sh --not-root         # Установка для текущего пользователя

ФАЙЛЫ:
    Лог:              $LOG_FILE
    Резервные копии:  $BACKUP_BASE_DIR
    Конфигурация:     $CONFIG_GLOBAL

УПРАВЛЕНИЕ ПОСЛЕ УСТАНОВКИ:
    motd-config       # CLI утилита для настройки отображения блоков

Подробнее: https://NeoNode.cc
EOF
}

configure_user_mode() {
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        DASHBOARD_FILE="$HOME/.config/neonode/99-dashboard"
        MOTD_CONFIG_TOOL="$HOME/.local/bin/motd-config"
        CONFIG_GLOBAL="$HOME/.motdrc"
        
        # Создаем директории
        mkdir -p "$(dirname "$DASHBOARD_FILE")" "$(dirname "$MOTD_CONFIG_TOOL")"
        
        log_info "Настроен пользовательский режим установки"
    fi
}

# ======================================================================
# ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ
# ======================================================================

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --install)
                OPERATION_MODE="install"
                ;;
            --restore)
                OPERATION_MODE="restore"
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --force)
                FORCE_MODE=true
                ;;
            --not-root)
                INSTALL_USER_MODE=true
                ;;
            *)
                log_warning "Неизвестный параметр: $arg"
                echo "💡 Используйте --help для справки"
                ;;
        esac
    done
    
    log_info "Режим работы: $OPERATION_MODE"
}

# ======================================================================
# СИСТЕМА РЕЗЕРВНОГО КОПИРОВАНИЯ
# ======================================================================

create_backup_directory() {
    local backup_dir="$BACKUP_BASE_DIR/$(date +%Y%m%d_%H%M%S)"
    
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        backup_dir="$HOME/.motd_backups/$(date +%Y%m%d_%H%M%S)"
    fi
    
    if ! mkdir -p "$backup_dir"; then
        fatal_error "Не удалось создать директорию резервных копий: $backup_dir"
    fi
    
    log_info "Создана директория резервных копий: $backup_dir"
    echo "$backup_dir"
}

find_existing_motd_files() {
    local files=()
    
    # Поиск в стандартных местах
    local search_paths=(
        "/etc/update-motd.d/"
        "/etc/motd"
        "/etc/motd.tail"
        "/etc/motd.dynamic"
        "/run/motd"
        "/run/motd.dynamic"
        "/var/run/motd"
        "/var/run/motd.dynamic"
    )
    
    for path in "${search_paths[@]}"; do
        if [[ -e "$path" ]]; then
            # Для директорий ищем все файлы
            if [[ -d "$path" ]]; then
                while IFS= read -r -d '' file; do
                    files+=("$file")
                done < <(find "$path" -type f -print0 2>/dev/null)
            else
                files+=("$path")
            fi
        fi
    done
    
    # Удаляем дубликаты и сортируем
    printf '%s\n' "${files[@]}" | sort -u
}

backup_existing_motd() {
    local backup_dir
    backup_dir=$(create_backup_directory)
    
    local backup_manifest="$backup_dir/backup_manifest.txt"
    local files_found=0
    
    log_info "Начинаем резервное копирование существующих MOTD файлов..."
    echo "# MOTD Backup Manifest - $(date)" > "$backup_manifest"
    echo "# Original -> Backup" >> "$backup_manifest"
    
    while IFS= read -r original_file; do
        if [[ -n "$original_file" && -e "$original_file" ]]; then
            local backup_file="$backup_dir$(dirname "$original_file")"
            local filename=$(basename "$original_file")
            
            # Создаем структуру директорий в резервной копии
            if ! mkdir -p "$backup_file"; then
                log_error "Не удалось создать директорию: $backup_file"
                continue
            fi
            
            # Копируем файл с сохранением всех атрибутов
            if cp -a "$original_file" "$backup_file/"; then
                echo "$original_file -> $backup_file/$filename" >> "$backup_manifest"
                
                # Сохраняем метаданные
                stat "$original_file" > "$backup_file/$filename.metadata" 2>/dev/null || true
                
                log_info "Сохранён: $original_file"
                ((files_found++))
            else
                log_error "Ошибка копирования: $original_file"
            fi
        fi
    done < <(find_existing_motd_files)
    
    if [[ $files_found -eq 0 ]]; then
        log_info "Существующие MOTD файлы не найдены"
        rmdir "$backup_dir" 2>/dev/null || true
        return 0
    fi
    
    # Создаем ссылку на последнюю резервную копию
    local latest_link
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        latest_link="$HOME/.motd_backups/latest"
    else
        latest_link="$BACKUP_BASE_DIR/latest"
    fi
    
    rm -f "$latest_link" 2>/dev/null || true
    ln -sf "$backup_dir" "$latest_link"
    
    log_info "Резервное копирование завершено. Файлов сохранено: $files_found"
    log_info "Резервная копия: $backup_dir"
    
    echo "$backup_dir"
}

remove_existing_motd() {
    log_info "Удаление существующих MOTD файлов..."
    local removed_count=0
    
    while IFS= read -r file; do
        if [[ -n "$file" && -e "$file" ]]; then
            if rm -f "$file" 2>/dev/null; then
                log_info "Удалён: $file"
                ((removed_count++))
            else
                log_warning "Не удалось удалить: $file"
            fi
        fi
    done < <(find_existing_motd_files)
    
    # Отключаем исполняемые права для файлов в /etc/update-motd.d/
    if [[ -d "/etc/update-motd.d" && "$INSTALL_USER_MODE" == false ]]; then
        find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \; 2>/dev/null || true
        log_info "Отключены остальные MOTD скрипты в /etc/update-motd.d/"
    fi
    
    log_info "Удаление завершено. Файлов удалено: $removed_count"
}

# ======================================================================
# СИСТЕМА ВОССТАНОВЛЕНИЯ
# ======================================================================

find_latest_backup() {
    local latest_link
    if [[ "$INSTALL_USER_MODE" == true ]]; then
        latest_link="$HOME/.motd_backups/latest"
    else
        latest_link="$BACKUP_BASE_DIR/latest"
    fi
    
    if [[ -L "$latest_link" && -d "$latest_link" ]]; then
        readlink -f "$latest_link"
    else
        # Ищем самую свежую директорию резервных копий
        local backup_base
        if [[ "$INSTALL_USER_MODE" == true ]]; then
            backup_base="$HOME/.motd_backups"
        else
            backup_base="$BACKUP_BASE_DIR"
        fi
        
        if [[ -d "$backup_base" ]]; then
            find "$backup_base" -maxdepth 1 -type d -name "[0-9]*_[0-9]*" | sort -r | head -n1
        fi
    fi
}

validate_backup() {
    local backup_dir="$1"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_error "Директория резервной копии не найдена: $backup_dir"
        return 1
    fi
    
    local manifest="$backup_dir/backup_manifest.txt"
    if [[ ! -f "$manifest" ]]; then
        log_warning "Манифест резервной копии не найден: $manifest"
        return 1
    fi
    
    log_info "Найдена валидная резервная копия: $backup_dir"
    return 0
}

restore_motd_backup() {
    log_info "Начинаем восстановление MOTD из резервной копии..."
    
    local backup_dir
    backup_dir=$(find_latest_backup)
    
    if [[ -z "$backup_dir" ]]; then
        fatal_error "Резервная копия не найдена. Восстановление невозможно."
    fi
    
    if ! validate_backup "$backup_dir"; then
        fatal_error "Резервная копия повреждена или некорректна: $backup_dir"
    fi
    
    log_info "Используется резервная копия: $backup_dir"
    
    # Удаляем наш MOTD дашборд
    if [[ -f "$DASHBOARD_FILE" ]]; then
        rm -f "$DASHBOARD_FILE"
        log_info "Удалён файл дашборда: $DASHBOARD_FILE"
    fi
    
    # Удаляем CLI утилиту
    if [[ -f "$MOTD_CONFIG_TOOL" ]]; then
        rm -f "$MOTD_CONFIG_TOOL"
        log_info "Удалена CLI утилита: $MOTD_CONFIG_TOOL"
    fi
    
    # Удаляем конфигурацию
    if [[ -f "$CONFIG_GLOBAL" ]]; then
        rm -f "$CONFIG_GLOBAL"
        log_info "Удалён конфиг: $CONFIG_GLOBAL"
    fi
    
    # Восстанавливаем файлы из резервной копии
    local manifest="$backup_dir/backup_manifest.txt"
    local restored_count=0
    
    while IFS=' -> ' read -r original_path backup_path; do
        # Пропускаем комментарии
        [[ "$original_path" =~ ^#.*$ ]] && continue
        [[ -z "$original_path" ]] && continue
        
        if [[ -f "$backup_path" ]]; then
            # Создаем директорию для файла если нужно
            local target_dir=$(dirname "$original_path")
            mkdir -p "$target_dir" 2>/dev/null || true
            
            # Восстанавливаем файл
            if cp -a "$backup_path" "$original_path"; then
                
                # Восстанавливаем метаданные если есть
                local metadata_file="$backup_path.metadata"
                if [[ -f "$metadata_file" ]]; then
                    # Извлекаем и восстанавливаем права доступа
                    local mode=$(grep "Access:" "$metadata_file" | head -n1 | sed 's/.*(\([0-9]*\).*/\1/')
                    [[ -n "$mode" ]] && chmod "$mode" "$original_path" 2>/dev/null || true
                fi
                
                log_info "Восстановлен: $original_path"
                ((restored_count++))
            else
                log_error "Ошибка восстановления: $original_path"
            fi
        fi
    done < "$manifest"
    
    # Включаем обратно MOTD скрипты
    if [[ -d "/etc/update-motd.d" && "$INSTALL_USER_MODE" == false ]]; then
        find /etc/update-motd.d/ -type f -exec chmod +x {} \; 2>/dev/null || true
        log_info "Включены стандартные MOTD скрипты"
    fi
    
    # Удаляем файлы отключения
    rm -f /tmp/.motd_disabled /tmp/.motd_cache /tmp/.motd_update_check 2>/dev/null || true
    
    log_info "Восстановление завершено успешно!"
    log_info "Файлов восстановлено: $restored_count"
    echo ""
    echo "✅ MOTD успешно восстановлен из резервной копии"
    echo "📁 Использована резервная копия: $backup_dir"
    echo "📊 Восстановлено файлов: $restored_count"
    echo ""
    echo "🔄 MOTD вернётся к стандартному виду при следующем входе в систему."
}

# ======================================================================
# ПРОВЕРКА ЗАВИСИМОСТЕЙ И УСТАНОВКА ПАКЕТОВ
# ======================================================================

check_dependencies() {
    log_info "Проверка необходимых утилит..."
    local missing=()
    local optional_missing=()
    
    # Обязательные утилиты
    local required_commands=(curl hostname awk grep cut uname df free uptime)
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Опциональные утилиты (не критичные)
    local optional_commands=(top ip vnstat)
    for cmd in "${optional_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            optional_missing+=("$cmd")
        fi
    done
    
    # Проверяем критичные утилиты
    if (( ${#missing[@]} )); then
        log_error "Не хватает обязательных утилит: ${missing[*]}"
        echo "🛠 Установите их командой:"
        if [[ "$EUID" -eq 0 ]]; then
            echo "    apt update && apt install curl coreutils net-tools procps iproute2 -y"
        else
            echo "    sudo apt update && sudo apt install curl coreutils net-tools procps iproute2 -y"
        fi
        echo "🔁 После этого снова запустите установку."
        fatal_error "Отсутствуют критически важные утилиты"
    fi
    
    # Предупреждаем об опциональных утилитах
    if (( ${#optional_missing[@]} )); then
        log_warning "Отсутствуют опциональные утилиты: ${optional_missing[*]}"
        echo "💡 Для полной функциональности рекомендуется установить:"
        if [[ "$EUID" -eq 0 ]]; then
            echo "    apt install vnstat sysstat iproute2 -y"
        else
            echo "    sudo apt install vnstat sysstat iproute2 -y"
        fi
        echo "📝 Скрипт будет работать без них, но с ограниченной функциональностью."
        
        # Предлагаем автоматическую установку
        local install_optional="n"
        if [[ "$FORCE_MODE" == false ]] && [[ -t 0 ]]; then
            read -p "🤖 Установить опциональные пакеты автоматически? [y/N]: " install_optional < /dev/tty
        elif [[ "$FORCE_MODE" == true ]]; then
            log_info "Автоматическая установка опциональных пакетов в force-режиме..."
            install_optional="y"
        fi
        
        if [[ "$install_optional" =~ ^[Yy]$ ]]; then
            install_optional_packages
        fi
    fi
}

install_optional_packages() {
    log_info "Установка опциональных пакетов..."
    
    local install_cmd="apt update >/dev/null 2>&1 && apt install vnstat sysstat iproute2 -y"
    if [[ "$EUID" -ne 0 ]]; then
        install_cmd="sudo $install_cmd"
    fi
    
    if eval "$install_cmd"; then
        log_info "Опциональные пакеты установлены успешно"
        initialize_vnstat
    else
        log_warning "Ошибка при установке опциональных пакетов"
    fi
}

initialize_vnstat() {
    if command -v vnstat >/dev/null 2>&1; then
        log_info "Инициализация vnstat..."
        
        # Определяем основной сетевой интерфейс
        local main_if
        main_if=$(ip route | grep default | awk '{print $5}' | head -n1 2>/dev/null)
        [[ -z "$main_if" ]] && main_if=$(ls /sys/class/net/ | grep -v lo | head -n1)
        
        if [[ -n "$main_if" ]]; then
            local vnstat_cmd="vnstat -i $main_if --create >/dev/null 2>&1 && systemctl enable vnstat >/dev/null 2>&1 && systemctl start vnstat >/dev/null 2>&1"
            if [[ "$EUID" -ne 0 ]]; then
                vnstat_cmd="sudo $vnstat_cmd"
            fi
            
            if eval "$vnstat_cmd"; then
                log_info "vnstat инициализирован для интерфейса $main_if"
            else
                log_warning "Ошибка инициализации vnstat"
            fi
        else
            log_warning "Не удалось определить сетевой интерфейс для vnstat"
        fi
    fi
}

# ======================================================================
# СОЗДАНИЕ И УСТАНОВКА КОМПОНЕНТОВ
# ======================================================================

install_motd_config() {
    log_info "Установка CLI утилиты motd-config в $MOTD_CONFIG_TOOL"
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
  echo "2) Отключить/Включить MOTD"
  echo "3) Обновить MOTD-дашборд"
  echo "4) Исправить дублирование MOTD"
  echo "5) Удалить MOTD-дашборд"
  echo "6) Восстановить оригинальный MOTD"
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

toggle_motd() {
  DISABLE_FILE="/tmp/.motd_disabled"
  if [ -f "$DISABLE_FILE" ]; then
    rm -f "$DISABLE_FILE"
    echo "✅ MOTD включен. Будет отображаться при следующем входе."
  else
    touch "$DISABLE_FILE"
    echo "❌ MOTD отключен. Создан файл $DISABLE_FILE"
    echo "💡 Для включения запустите снова эту команду или удалите файл."
  fi
}

update_dashboard() {
  echo "🔄 Обновление MOTD-дашборда..."
  REMOTE_URL="https://famebloody.github.io/server/dashboard-refactored.sh"
  
  if ! curl -s --connect-timeout 5 "$REMOTE_URL" >/dev/null; then
    echo "❌ Не удалось подключиться к $REMOTE_URL"
    echo "🌐 Проверьте интернет-соединение и попробуйте позже."
    return 1
  fi
  
  echo "📥 Скачиваем новую версию..."
  if curl -s "$REMOTE_URL" | bash -s -- --force; then
    echo "✅ MOTD-дашборд успешно обновлен!"
  else
    echo "❌ Ошибка при обновлении. Попробуйте вручную:"
    echo "   bash <(curl -s $REMOTE_URL) --force"
  fi
}

fix_duplicate_motd() {
  echo "🔧 Исправление дублирования MOTD..."
  
  if [ -d "/etc/update-motd.d" ]; then
    sudo find /etc/update-motd.d/ -type f -not -name "99-dashboard" -exec chmod -x {} \; 2>/dev/null
    echo "✅ Отключены все MOTD скрипты кроме 99-dashboard"
  fi
  
  for file in /etc/motd /run/motd.dynamic; do
    if [ -f "$file" ]; then
      sudo mv "$file" "${file}.disabled" 2>/dev/null
      echo "✅ Отключен файл: $file"
    fi
  done
  
  DASHBOARD_COUNT=$(find /etc/update-motd.d/ -name "*dashboard*" -type f | wc -l)
  if [ "$DASHBOARD_COUNT" -gt 1 ]; then
    echo "⚠️ Найдено $DASHBOARD_COUNT файлов dashboard!"
    find /etc/update-motd.d/ -name "*dashboard*" -type f -exec ls -la {} \;
    echo "🛠 Удаляем дубликаты, оставляем только 99-dashboard..."
    sudo find /etc/update-motd.d/ -name "*dashboard*" -not -name "99-dashboard" -delete 2>/dev/null
  fi
  
  echo "✅ Проблема дублирования исправлена!"
}

restore_original_motd() {
  echo "🔄 Восстановление оригинального MOTD из резервной копии..."
  bash <(curl -s https://famebloody.github.io/server/dashboard.sh) --restore
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
    
    rm -f /tmp/.motd_disabled
    rm -f /tmp/.motd_cache
    rm -f /tmp/.motd_update_check

    for file in /etc/motd.disabled /run/motd.dynamic.disabled; do
      if [ -f "$file" ]; then
        original_file="${file%.disabled}"
        sudo mv "$file" "$original_file" 2>/dev/null
        echo "✅ Восстановлен файл: $original_file"
      fi
    done

    if [ -d "/etc/update-motd.d" ]; then
      sudo find /etc/update-motd.d/ -type f -exec chmod +x {} \; 2>/dev/null
    fi

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
    2) toggle_motd ;;
    3) update_dashboard ;;
    4) fix_duplicate_motd ;;
    5) uninstall_dashboard ;;
    6) restore_original_motd ;;
    0) exit ;;
    *) echo "❌ Неверный ввод" ;;
  esac
  echo ""
done 
EOF

    chmod +x "$MOTD_CONFIG_TOOL"
    check_error "Установка CLI утилиты motd-config"
    log_info "Установлена CLI утилита: $MOTD_CONFIG_TOOL"
}

create_motd_global_config() {
    if [[ ! -f "$CONFIG_GLOBAL" ]]; then
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
        check_error "Создание глобального конфига"
        log_info "Создан глобальный конфиг: $CONFIG_GLOBAL"
    else
        log_info "Глобальный конфиг уже существует: $CONFIG_GLOBAL"
    fi
}

create_dashboard_file() {
    local tmp_file
    tmp_file=$(mktemp)
    
    log_info "Создание MOTD dashboard файла..."
    
    cat > "$tmp_file" << 'EOF'
#!/bin/bash

# ОПТИМИЗАЦИЯ: Проверка на быстрое отключение MOTD
if [[ -f "/tmp/.motd_disabled" ]] || [[ "$SSH_CLIENT_IP" = "DISABLED" ]]; then
    exit 0
fi

# ОПТИМИЗАЦИЯ: Таймаут для всех операций с сохранением кода возврата
exec_with_timeout() {
    local exit_code
    timeout 3 "$@" 2>/dev/null
    exit_code=$?
    
    # timeout возвращает 124 при превышении времени, 
    # в остальных случаях возвращает код выхода команды
    if [[ $exit_code -eq 124 ]]; then
        echo "timeout"
        return 1
    else
        return $exit_code
    fi
}

CURRENT_VERSION="2025.07.30-refactored"

# ОПТИМИЗАЦИЯ: Проверка обновлений только раз в час
UPDATE_CHECK_FILE="/tmp/.motd_update_check"
if [[ ! -f "$UPDATE_CHECK_FILE" ]] || [[ $(($(date +%s) - $(stat -c %Y "$UPDATE_CHECK_FILE" 2>/dev/null || echo 0))) -gt 3600 ]]; then
    REMOTE_URL="https://famebloody.github.io/server/dashboard.sh"
    REMOTE_VERSION=$(exec_with_timeout curl -s --connect-timeout 2 "$REMOTE_URL" | grep '^CURRENT_VERSION=' | cut -d= -f2 | tr -d '"')
    
    if [[ -n "$REMOTE_VERSION" ]] && [[ "$REMOTE_VERSION" != "$CURRENT_VERSION" ]]; then
        echo "⚠️ Доступна новая версия MOTD-дашборда: $REMOTE_VERSION (текущая: $CURRENT_VERSION)"
        echo "💡 Обновление: bash <(curl -s $REMOTE_URL) --force"
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
[[ -f "$CONFIG_GLOBAL" ]] && source "$CONFIG_GLOBAL"
[[ -f "$CONFIG_USER" ]] && source "$CONFIG_USER"

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

if [[ -f "$CACHE_FILE" ]] && [[ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))) -lt $CACHE_TIME ]]; then
    source "$CACHE_FILE"
else
    # Собираем данные только если кэш устарел
    uptime_str=$(exec_with_timeout uptime -p || echo "uptime unavailable")
    loadavg=$(exec_with_timeout cat /proc/loadavg | cut -d ' ' -f1-3 || echo "load unavailable")
    
    # CPU usage с проверкой наличия top
    if command -v top >/dev/null 2>&1; then
        cpu_usage=$(exec_with_timeout top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8 "%"}' | head -1)
        [[ -z "$cpu_usage" ]] && cpu_usage="n/a"
    else
        cpu_usage="top not available"
    fi
    
    mem_data=$(exec_with_timeout free -m | awk '/Mem:/ {printf "%.0f%% (%dMB/%dMB)", $3/$2*100, $3, $2}' || echo "memory info unavailable")
    
    disk_used=$(exec_with_timeout df -h / | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
    disk_line=$(exec_with_timeout df -h / | awk 'NR==2 {print $5 " (" $3 " / " $2 ")"}' || echo "disk info unavailable")
    
    if [[ "$disk_used" -ge 95 ]] 2>/dev/null; then
        disk_status="$fail $disk_line [CRITICAL: Free up space immediately!]"
    elif [[ "$disk_used" -ge 85 ]] 2>/dev/null; then
        disk_status="$warn $disk_line [Warning: High usage]"
    else
        disk_status="$ok $disk_line"
    fi

    # ОПТИМИЗАЦИЯ: vnstat как в оригинале
    if command -v vnstat >/dev/null 2>&1; then
        traffic=$(exec_with_timeout vnstat --oneline | awk -F\; '{print $10 " ↓ / " $11 " ↑"}')
        [[ -z "$traffic" ]] && traffic="vnstat: no data yet"
    else
        traffic="vnstat not installed"
    fi
    
    ip_local=$(exec_with_timeout hostname -I | awk '{print $1}' || echo "n/a")
    
    # ОПТИМИЗАЦИЯ: Публичный IP с коротким таймаутом
    ip_public=$(exec_with_timeout curl -s --connect-timeout 1 --max-time 2 ifconfig.me || echo "n/a")
    
    # NetBird IP проверка
    if command -v netbird >/dev/null 2>&1; then
        netbird_ip=$(exec_with_timeout netbird status | grep "NetBird IP:" | awk '{print $3}' | cut -d'/' -f1)
        [[ -z "$netbird_ip" ]] && netbird_ip="not connected"
    else
        netbird_ip="not installed"
    fi
    
    # IPv6 с проверкой наличия ip команды
    if command -v ip >/dev/null 2>&1; then
        ip6=$(exec_with_timeout ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)
    else
        ip6="ip command not available"
    fi
    [[ -z "$ip6" ]] && ip6="n/a"

    # Docker информация с проверкой доступности
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker_total=$(exec_with_timeout docker ps -a -q | wc -l)
        docker_running=$(exec_with_timeout docker ps -q | wc -l)
        docker_stopped=$((docker_total - docker_running))
        docker_msg="$ok ${docker_running} running / ${docker_stopped} stopped"
        
        bad_containers=$(exec_with_timeout docker ps -a --filter "status=exited" --filter "status=restarting" --format '⛔ {{.Names}} ({{.Status}})' | head -3)
        if [[ -n "$bad_containers" ]]; then
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
    [[ -z "$ssh_port" ]] && ssh_port=22
    [[ "$ssh_port" != "22" ]] && ssh_port_status="$ok non-standard port ($ssh_port)" || ssh_port_status="$warn default port (22)"

    permit_root=$(exec_with_timeout sshd -T 2>/dev/null | grep -i permitrootlogin | awk '{print $2}')
    case "$permit_root" in
        yes) root_login_status="$fail enabled" ;;
        no) root_login_status="$ok disabled" ;;
        *) root_login_status="$warn limited ($permit_root)" ;;
    esac

    password_auth=$(grep -Ei '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [[ "$password_auth" != "yes" ]] && password_auth_status="$ok disabled" || password_auth_status="$fail enabled"

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
netbird_ip="$netbird_ip"
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
    ip)           
      # Формируем строку с IP-адресами
      ip_info="Local: $ip_local / Public: $ip_public"
      ip_info="$ip_info / IPv6: $ip6"
      print_row "IPv4/IPv6" "$ip_info"
      if [[ "$netbird_ip" != "not installed" ]]; then
        print_row "NetBird" "$netbird_ip"
      fi
      ;;
    docker)
      print_row "Docker" "$docker_msg"
      [[ -n "$docker_msg_extra" ]] && echo -e "$docker_msg_extra"
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
[[ "$SHOW_UPTIME" = true ]] && print_section uptime
[[ "$SHOW_LOAD" = true ]] && print_section load
[[ "$SHOW_CPU" = true ]] && print_section cpu
print_section kernel
[[ "$SHOW_RAM" = true ]] && print_section ram
[[ "$SHOW_DISK" = true ]] && print_section disk
[[ "$SHOW_NET" = true ]] && print_section net
[[ "$SHOW_IP" = true ]] && print_section ip
[[ "$SHOW_DOCKER" = true ]] && print_section docker
[[ "$SHOW_SECURITY" = true ]] && print_section ssh_block
[[ "$SHOW_UPDATES" = true ]] && print_section updates
[[ "$SHOW_AUTOUPDATES" = true ]] && print_section autoupdates

echo ""
printf " %-20s : %s\n" "Dashboard Ver" "$CURRENT_VERSION"
echo "$separator"
printf " %-20s : %s\n" "Config tool" "motd-config"
EOF

    echo "$tmp_file"
}

# ======================================================================
# ОСНОВНЫЕ ОПЕРАЦИИ
# ======================================================================

perform_installation() {
    log_info "Начинаем установку MOTD дашборда..."
    
    # Проверка прав доступа
    if [[ "$EUID" -ne 0 ]] && [[ "$INSTALL_USER_MODE" == false ]]; then
        fatal_error "Пожалуйста, запустите от root или с флагом --not-root"
    fi
    
    # Проверка способа запуска
    if [[ ! -t 0 ]]; then
        log_info "Скрипт запущен через pipe (wget/curl). Включен автоматический режим."
        FORCE_MODE=true
        echo "💡 Для интерактивного режима скачайте скрипт: wget https://famebloody.github.io/server/dashboard.sh && bash dashboard.sh"
        echo ""
    fi
    
    # Создание резервной копии
    backup_existing_motd
    
    # Удаление существующих MOTD файлов
    remove_existing_motd
    
    # Создание структуры директорий
    if [[ "$INSTALL_USER_MODE" == false ]]; then
        mkdir -p /etc/update-motd.d
        check_error "Создание директории /etc/update-motd.d"
    fi
    
    # Создание dashboard файла
    local tmp_dashboard
    tmp_dashboard=$(create_dashboard_file)
    
    # Предпросмотр
    echo "===================================================="
    echo "📋 Предпросмотр NeoNode MOTD (оптимизированная версия):"
    echo "===================================================="
    bash "$tmp_dashboard"
    echo "===================================================="
    
    # Подтверждение установки
    local confirm="y"
    if [[ "$FORCE_MODE" == false ]] && [[ -t 0 ]]; then
        echo "Будет выполнена установка оптимизированного набора:"
        echo "👉 Будет установлен дашборд: $DASHBOARD_FILE"
        echo "👉 Будет установлена CLI утилита: $MOTD_CONFIG_TOOL"
        echo "👉 Будет создан глобальный конфиг: $CONFIG_GLOBAL"
        echo ""
        echo "🚀 ОПТИМИЗАЦИИ:"
        echo "   • Кэширование данных на 30 секунд"
        echo "   • Таймауты для всех команд (3 сек)"
        echo "   • Проверка обновлений раз в час"
        echo "   • Управление через motd-config"
        echo "   • Система резервного копирования и восстановления"
        echo ""
        
        read -p '❓ Установить этот оптимизированный MOTD-дэшборд? [y/N]: ' confirm < /dev/tty
    fi
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Установка dashboard файла
        mv "$tmp_dashboard" "$DASHBOARD_FILE"
        check_error "Установка dashboard файла"
        
        if [[ "$INSTALL_USER_MODE" == false ]]; then
            chmod +x "$DASHBOARD_FILE"
            check_error "Установка прав доступа на dashboard файл"
        fi
        
        # Установка CLI утилиты и конфигурации
        install_motd_config
        create_motd_global_config
        
        log_info "Установка завершена успешно!"
        echo ""
        echo "✅ Установлен оптимизированный дашборд: $DASHBOARD_FILE"
        echo "✅ Установлена CLI утилита: $MOTD_CONFIG_TOOL"
        echo "✅ Создан глобальный конфиг: $CONFIG_GLOBAL"
        echo ""
        echo "🚀 НОВЫЕ ВОЗМОЖНОСТИ:"
        echo "   • Автоматическое резервное копирование при установке"
        echo "   • Восстановление оригинального MOTD через --restore"
        echo "   • Детальное логирование в $LOG_FILE"
        echo "   • Улучшенная обработка ошибок"
        echo ""
        echo "👉 Для настройки отображения блоков — выполните: motd-config"
        echo "👉 Для восстановления оригинального MOTD — выполните: $(basename "$0") --restore"
        echo "👉 Обновлённый MOTD появится при следующем входе"
        
    else
        rm -f "$tmp_dashboard"
        log_info "Установка отменена пользователем"
        echo "❌ Установка отменена."
    fi
}

# ======================================================================
# ОСНОВНАЯ ЛОГИКА ВЫПОЛНЕНИЯ
# ======================================================================

main() {
    # Обработка аргументов
    parse_arguments "$@"
    
    # Настройка режимов
    configure_user_mode
    
    # Логируем начало работы
    log_info "Запуск скрипта, режим: $OPERATION_MODE, версия: $SCRIPT_VERSION"
    log_info "Пользовательский режим: $INSTALL_USER_MODE, принудительный режим: $FORCE_MODE"
    
    case "$OPERATION_MODE" in
        "install")
            check_dependencies
            perform_installation
            ;;
        "restore")
            restore_motd_backup
            ;;
        *)
            fatal_error "Неизвестный режим работы: $OPERATION_MODE"
            ;;
    esac
    
    log_info "Скрипт завершен успешно"
}

# Запуск основной функции
main "$@"
