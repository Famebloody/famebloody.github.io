#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Welcome to SHM Backup Installer${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${BLUE}This script will create a ${YELLOW}backup.sh${BLUE} file with your settings.${NC}"
echo

prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    echo -ne "${prompt} [${default}]: "
    read input
    eval "$var_name=\"${input:-$default}\""
}

echo -e "${YELLOW}📍 Specify the path to docker-compose.yml for SHM:${NC}"
echo -e "${BLUE}  1) /root/shm${NC}"
echo -e "${BLUE}  2) /opt/shm${NC}"
echo -e "${BLUE}  3) Enter manually${NC}"
echo -e "${GREEN}Note:${NC} Info from .env and other files will be read from this path."
echo -ne "Choose an option (1-3) [2]: "
read choice
choice=${choice:-2}

case $choice in
    1) COMPOSE_PATH="/root/shm" ;;
    2) COMPOSE_PATH="/opt/shm" ;;
    3) prompt_input "${YELLOW}Enter the path manually${NC}" COMPOSE_PATH "" ;;
    *) COMPOSE_PATH="/opt/shm" ;;
esac

if [ ! -f "$COMPOSE_PATH/docker-compose.yml" ]; then
    echo -e "${RED}✖ Error: docker-compose.yml not found at $COMPOSE_PATH${NC}"
    exit 1
fi

echo -e "${YELLOW}📁 Do you want to backup the entire folder ($COMPOSE_PATH)?${NC}"
echo -e "${BLUE}  1) Yes, backup all files and subfolders${NC}"
echo -e "${BLUE}  2) No, backup only specific files (docker-compose.yml, .env)${NC}"
echo -ne "Choose an option (1-2) [1]: "
read backup_choice
backup_choice=${backup_choice:-1}

case $backup_choice in
    1) BACKUP_ENTIRE_FOLDER="true" ;;
    2) BACKUP_ENTIRE_FOLDER="false" ;;
    *) BACKUP_ENTIRE_FOLDER="true" ;;
esac

read_env_var() {
    local var_name="$1"
    local file="$2"
    local value
    value=$(grep "^$var_name=" "$file" | cut -d '=' -f 2-)
    echo "$value"
}

if [ -f "$COMPOSE_PATH/.env" ]; then
    echo -e "${GREEN}✔ .env file found at $COMPOSE_PATH. Using it for DB connection.${NC}"
    USE_ENV=true
    MYSQL_USER=$(read_env_var "MYSQL_USER" "$COMPOSE_PATH/.env")
    MYSQL_PASS=$(read_env_var "MYSQL_PASS" "$COMPOSE_PATH/.env")
    MYSQL_DATABASE=$(read_env_var "MYSQL_DATABASE" "$COMPOSE_PATH/.env")
    MYSQL_USER=${MYSQL_USER:-root}
    MYSQL_DATABASE=${MYSQL_DATABASE:-shm}
    if [ -z "$MYSQL_PASS" ]; then
        echo -e "${YELLOW}⚠ MYSQL_PASS not found in .env file. Will use environment variables at runtime.${NC}"
    fi
else
    echo -e "${YELLOW}⚠ .env file not found at $COMPOSE_PATH.${NC}"
    echo -e "${BLUE}You'll need to enter DB connection details manually.${NC}"
    USE_ENV=false
    prompt_input "${YELLOW}Enter MYSQL_USER${NC}" MYSQL_USER "root"
    prompt_input "${YELLOW}Enter MYSQL_PASS${NC}" MYSQL_PASS ""
    prompt_input "${YELLOW}Enter MYSQL_DATABASE${NC}" MYSQL_DATABASE "shm"
fi

DB_CONTAINER=$(docker ps --filter "name=mysql" --format "{{.Names}}")
if [ -z "$DB_CONTAINER" ]; then
    echo -e "${YELLOW}⚠ Database container 'mysql' not found!${NC}"
    echo -e "${BLUE}Please enter the correct container name for the database:${NC}"
    prompt_input "${YELLOW}Enter DB container name${NC}" DB_CONTAINER "mysql"
fi

echo -e "${YELLOW}📡 Telegram Settings:${NC}"
prompt_input "${BLUE}Enter Telegram Bot Token (from @BotFather)${NC}" TELEGRAM_BOT_TOKEN ""
prompt_input "${BLUE}Enter Telegram Chat/Channel ID (e.g., -1001234567890)${NC}" TELEGRAM_CHAT_ID ""
prompt_input "${BLUE}Enter Telegram Topic ID (optional, press Enter to skip)${NC}" TELEGRAM_TOPIC_ID ""

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    echo -e "${RED}✖ Error: Telegram Bot Token and Chat ID are required!${NC}"
    exit 1
fi

BACKUP_SCRIPT="$COMPOSE_PATH/backup.sh"
cat << EOF > "$BACKUP_SCRIPT"
#!/bin/bash
cd "$COMPOSE_PATH" || { echo "Error: Could not change to $COMPOSE_PATH"; exit 1; }
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
TELEGRAM_TOPIC_ID="$TELEGRAM_TOPIC_ID"
BACKUP_DIR="/tmp/backup_\$(date +%Y%m%d_%H%M%S)"
BACKUP_DATE="\$(date '+%Y-%m-%d %H:%M:%S UTC')"
ARCHIVE_NAME="\$BACKUP_DIR.tar.gz"
MAX_SIZE_MB=49
DB_CONTAINER="$DB_CONTAINER"
EOF

if [ "$USE_ENV" = "true" ]; then
    cat << EOF >> "$BACKUP_SCRIPT"
# Source environment variables from docker-compose
source $COMPOSE_PATH/.env
MYSQL_USER="\${MYSQL_USER}"
MYSQL_PASS="\${MYSQL_PASS}"
MYSQL_DATABASE="\${MYSQL_DATABASE}"
EOF
else
    cat << EOF >> "$BACKUP_SCRIPT"
MYSQL_USER="$MYSQL_USER"
MYSQL_PASS="$MYSQL_PASS"
MYSQL_DATABASE="$MYSQL_DATABASE"
EOF
fi

cat << EOF >> "$BACKUP_SCRIPT"
mkdir -p "\$BACKUP_DIR"

# Create MySQL backup with --no-tablespaces to avoid permission issues
docker exec "\$DB_CONTAINER" mysqldump --no-tablespaces -u "\$MYSQL_USER" -p"\$MYSQL_PASS" "\$MYSQL_DATABASE" > "\$BACKUP_DIR/db_backup.sql"
if [ \$? -ne 0 ]; then
    echo "Error: Failed to create database backup"
    exit 1
fi
EOF

if [ "$BACKUP_ENTIRE_FOLDER" = "true" ]; then
    cat << EOF >> "$BACKUP_SCRIPT"
TEMP_ARCHIVE_DIR="/tmp/archive_\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\$TEMP_ARCHIVE_DIR"
cp -r "$COMPOSE_PATH/." "\$TEMP_ARCHIVE_DIR/"
mv "\$BACKUP_DIR/db_backup.sql" "\$TEMP_ARCHIVE_DIR/db_backup.sql"
tar -czvf "\$ARCHIVE_NAME" -C "\$TEMP_ARCHIVE_DIR" .
if [ \$? -ne 0 ]; then
    echo "Error: Failed to create archive"
    rm -rf "\$TEMP_ARCHIVE_DIR"
    exit 1
fi
rm -rf "\$TEMP_ARCHIVE_DIR"
CONTENTS="📁 Entire folder ($COMPOSE_PATH)
📋 db_backup.sql (MySQL)"
EOF
else
    cat << 'EOF' >> "$BACKUP_SCRIPT"
cp docker-compose.yml "$BACKUP_DIR/" || { echo "Error: Failed to copy docker-compose.yml"; exit 1; }
[ -f .env ] && cp .env "$BACKUP_DIR/" || echo "File .env not found, skipping"
CONTENTS=""
[ -f "$BACKUP_DIR/db_backup.sql" ] && CONTENTS="$CONTENTS📋 db_backup.sql (MySQL)
"
[ -f "$BACKUP_DIR/docker-compose.yml" ] && CONTENTS="$CONTENTS📄 docker-compose.yml
"
[ -f "$BACKUP_DIR/.env" ] && CONTENTS="$CONTENTS🔑 .env
"
tar -czvf "$ARCHIVE_NAME" -C "$BACKUP_DIR" .
if [ $? -ne 0 ]; then
    echo "Error: Failed to create archive"
    exit 1
fi
EOF
fi

cat << 'EOF' >> "$BACKUP_SCRIPT"
ARCHIVE_SIZE=$(du -m "$ARCHIVE_NAME" | cut -f1)
MESSAGE=$(printf "🔔 SHM Backup\n📅 Date: %s\n📦 Archive contents:\n%s" "$BACKUP_DATE" "$CONTENTS")
send_telegram() {
    local file="$1"
    local caption="$2"
    local curl_cmd="curl -F chat_id=\"\$TELEGRAM_CHAT_ID\""
    [ -n "$TELEGRAM_TOPIC_ID" ] && curl_cmd="$curl_cmd -F message_thread_id=\"\$TELEGRAM_TOPIC_ID\""
    curl_cmd="$curl_cmd -F document=@\"\$file\" -F \"caption=\$caption\" \"https://api.telegram.org/bot\$TELEGRAM_BOT_TOKEN/sendDocument\" -o telegram_response.json"
    eval "$curl_cmd"
}
if [ "$ARCHIVE_SIZE" -gt "$MAX_SIZE_MB" ]; then
    echo "Archive size ($ARCHIVE_SIZE MB) exceeds $MAX_SIZE_MB MB, splitting into parts..."
    split -b 49m "$ARCHIVE_NAME" "$BACKUP_DIR/part_"
    PARTS=("$BACKUP_DIR"/part_*)
    PART_COUNT=${#PARTS[@]}
    for i in "${!PARTS[@]}"; do
        PART_FILE="${PARTS[$i]}"
        PART_NUM=$((i + 1))
        PART_MESSAGE=$(printf "🔔 SHM Backup (Part %d of %d)\n📅 Date: %s\n📦 Archive contents:\n\n%s" "$PART_NUM" "$PART_COUNT" "$BACKUP_DATE" "$CONTENTS")
        send_telegram "$PART_FILE" "$PART_MESSAGE"
        if [ $? -ne 0 ] || grep -q '"ok":false' telegram_response.json; then
            echo "Error sending part $PART_NUM:"
            cat telegram_response.json
            exit 1
        fi
        echo "Part $PART_NUM of $PART_COUNT sent successfully"
    done
else
    send_telegram "$ARCHIVE_NAME" "$MESSAGE"
    if [ $? -ne 0 ]; then
        echo "Error sending archive to Telegram"
        cat telegram_response.json
        exit 1
    fi
    if grep -q '"ok":false' telegram_response.json; then
        echo "Telegram returned an error:"
        cat telegram_response.json
    else
        echo "Archive successfully sent to Telegram"
    fi
fi
rm -rf "$BACKUP_DIR"
rm "$ARCHIVE_NAME"
rm telegram_response.json
EOF

chmod +x "$BACKUP_SCRIPT"

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Backup script created successfully at: $BACKUP_SCRIPT${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${BLUE}To run it, use: ${YELLOW}$BACKUP_SCRIPT${NC}"
echo -e "${BLUE}To add to crontab, run '${YELLOW}crontab -e${BLUE}' and add, e.g.:${NC}"
echo -e "${YELLOW}0 */2 * * * $BACKUP_SCRIPT${NC}"
