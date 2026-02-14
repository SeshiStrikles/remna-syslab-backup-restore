#!/bin/bash

# ==============================================================================
# REMNA SYSLAB BACKUP & RESTORE TOOL v3.2
# Autonomous Backup System with Error Monitoring & Quantity Rotation
# ==============================================================================

# --- КОНФИГУРАЦИЯ (Заполняется автоматически) ---
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_TOPIC_ID=""
PROJECT_DIR="" 
MAX_BACKUPS_COUNT="30" # Сколько штук хранить (не дней, а файлов)
INSTALL_DIR="/opt/remna-syslab-backup-restore"
BACKUP_DIR="/opt/remna-syslab-backup-restore/backup"
REPO_URL="https://raw.githubusercontent.com/SeshiStrikles/remna-syslab-backup-restore/main/remna-syslab-backup-restore.sh"
# ----------------------------------------------------------------

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запуск только от root (sudo).${NC}"
  exit 1
fi

# --- ФУНКЦИЯ СОХРАНЕНИЯ НАСТРОЕК ---
save_config() {
    local target_file="$1"
    sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"|" "$target_file"
    sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$TG_CHAT_ID\"|" "$target_file"
    sed -i "s|^TG_TOPIC_ID=.*|TG_TOPIC_ID=\"$TG_TOPIC_ID\"|" "$target_file"
    sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=\"$PROJECT_DIR\"|" "$target_file"
    sed -i "s|^MAX_BACKUPS_COUNT=.*|MAX_BACKUPS_COUNT=\"$MAX_BACKUPS_COUNT\"|" "$target_file"
}

# --- ФУНКЦИЯ ОТПРАВКИ ОШИБОК ---
send_error_alert() {
    local error_msg="$1"
    echo -e "${RED}ERROR: $error_msg${NC}"
    
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d message_thread_id="$TG_TOPIC_ID" \
        -d text="❌ <b>ОШИБКА БЭКАПА!</b>%0A%0AПричина: <i>$error_msg</i>%0A%0AСервер: $(hostname)" \
        -d parse_mode="HTML" > /dev/null
}

# --- ИНСТАЛЛЯТОР ---
install_script() {
    echo -e "${GREEN}=== Установка Remna SysLab Backup Tool ===${NC}"
    
    if ! command -v zip &> /dev/null || ! command -v curl &> /dev/null; then
        apt-get update && apt-get install -y zip curl
    fi

    echo -e "\n${YELLOW}[Настройка путей]${NC}"
    read -p "Укажите путь к проекту VpnManager [/opt/VpnManager]: " input_dir
    PROJECT_DIR=${input_dir:-/opt/VpnManager}
    
    if [ ! -d "$PROJECT_DIR" ]; then
        echo -e "${RED}Ошибка: Директория $PROJECT_DIR не найдена!${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}[Настройка Telegram для бэкапов]${NC}"
    read -p "Telegram BOT_TOKEN: " TG_BOT_TOKEN
    read -p "Telegram CHAT_ID: " TG_CHAT_ID
    read -p "TOPIC_ID (Enter если нет): " TG_TOPIC_ID
    
    read -p "Сколько последних бэкапов хранить? [30]: " max_cnt
    MAX_BACKUPS_COUNT=${max_cnt:-30}

    mkdir -p "$BACKUP_DIR"

    TARGET_SCRIPT="$INSTALL_DIR/remna-syslab-backup-restore.sh"
    mkdir -p "$INSTALL_DIR"
    
    cp "$0" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"
    
    save_config "$TARGET_SCRIPT"

    echo -e "\n${GREEN}✔ Установка завершена! Запускаю...${NC}\n"
    exec "$TARGET_SCRIPT"
}

# --- САМООБНОВЛЕНИЕ ---
self_update() {
    echo -e "\n${YELLOW}Проверка обновлений...${NC}"
    TMP_FILE="/tmp/remna_update.sh"
    
    if curl -sSL "$REPO_URL" -o "$TMP_FILE"; then
        if [ ! -s "$TMP_FILE" ] || ! grep -q "#!/bin/bash" "$TMP_FILE"; then
             echo -e "${RED}Ошибка: Некорректный файл обновления.${NC}"
             return
        fi

        echo "Перенос настроек в новую версию..."
        save_config "$TMP_FILE"
        
        mv "$TMP_FILE" "$INSTALL_DIR/remna-syslab-backup-restore.sh"
        chmod +x "$INSTALL_DIR/remna-syslab-backup-restore.sh"
        
        echo -e "${GREEN}✔ Скрипт обновлен! Перезапускаю...${NC}"
        sleep 1
        exec "$INSTALL_DIR/remna-syslab-backup-restore.sh"
    else
        echo -e "${RED}Не удалось скачать обновление с GitHub.${NC}"
    fi
}

# --- РЕДАКТОР НАСТРОЕК ---
edit_settings() {
    echo -e "\n${YELLOW}=== Редактирование настроек ===${NC}"
    read -p "Путь к проекту [$PROJECT_DIR]: " new_dir
    PROJECT_DIR=${new_dir:-$PROJECT_DIR}
    
    read -p "Telegram Token [${TG_BOT_TOKEN:0:10}...]: " new_token
    TG_BOT_TOKEN=${new_token:-$TG_BOT_TOKEN}
    
    read -p "Chat ID [$TG_CHAT_ID]: " new_chat
    TG_CHAT_ID=${new_chat:-$TG_CHAT_ID}
    
    read -p "Topic ID [$TG_TOPIC_ID]: " new_topic
    TG_TOPIC_ID=${new_topic:-$TG_TOPIC_ID}
    
    read -p "Хранить штук [$MAX_BACKUPS_COUNT]: " new_max
    MAX_BACKUPS_COUNT=${new_max:-$MAX_BACKUPS_COUNT}
    
    save_config "$0"
    echo -e "${GREEN}✔ Настройки обновлены!${NC}"
}

# --- БЭКАП ---
perform_backup() {
    if [ -z "$TG_BOT_TOKEN" ]; then 
        echo -e "${RED}Не настроен токен!${NC}"; exit 1
    fi
    
    if [ ! -f "$PROJECT_DIR/.env" ]; then
        send_error_alert "Файл .env не найден в $PROJECT_DIR"
        exit 1
    fi
    
    export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
    
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    SQL_FILE="$BACKUP_DIR/db_$TIMESTAMP.sql"
    ZIP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.zip"
    
    echo "Дамп базы..."
    DUMP_OUTPUT=$(docker exec vpnmanager_postgres pg_dump -U "${DB_USER}" "${DB_NAME}" > "$SQL_FILE" 2>&1)
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -ne 0 ]; then
        rm "$SQL_FILE" 2>/dev/null
        send_error_alert "Ошибка pg_dump (Код: $EXIT_CODE). Детали: $DUMP_OUTPUT"
        exit 1
    fi
    
    if [ ! -s "$SQL_FILE" ]; then
        rm "$SQL_FILE"
        send_error_alert "Файл дампа базы пустой."
        exit 1
    fi
    
    echo "Архивация..."
    ZIP_OUTPUT=$(zip -j "$ZIP_FILE" "$SQL_FILE" "$PROJECT_DIR/.env" 2>&1)
    if [ $? -ne 0 ]; then
        send_error_alert "Ошибка ZIP. Детали: $ZIP_OUTPUT"
        rm "$SQL_FILE"
        exit 1
    fi
    rm "$SQL_FILE"
    
    echo "Отправка в Telegram..."
    RESPONSE=$(curl -s -F chat_id="$TG_CHAT_ID" -F message_thread_id="$TG_TOPIC_ID" \
         -F document=@"$ZIP_FILE" \
         -F caption="📦 Remna Backup: $TIMESTAMP" \
         "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument")
         
    if ! echo "$RESPONSE" | grep -q '"ok":true'; then
        send_error_alert "Ошибка API Telegram: $RESPONSE"
        exit 1
    fi
         
    # --- РОТАЦИЯ ПО КОЛИЧЕСТВУ ---
    # Переходим в папку бэкапов
    cd "$BACKUP_DIR" || exit
    # Считаем файлы zip
    COUNT=$(ls -1 backup_*.zip 2>/dev/null | wc -l)
    
    if [ "$COUNT" -gt "$MAX_BACKUPS_COUNT" ]; then
        echo "Чистка старых бэкапов (Лимит: $MAX_BACKUPS_COUNT, Сейчас: $COUNT)..."
        # ls -1t: сортировка по времени (новые сверху)
        # tail -n +X: берем все файлы начиная с (Limit+1) - то есть старые
        # xargs rm: удаляем их
        ls -1t backup_*.zip | tail -n +$((MAX_BACKUPS_COUNT + 1)) | xargs rm -f
        echo "Старые копии удалены."
    fi
    
    echo -e "${GREEN}✔ Бэкап успешно выполнен.${NC}"
}

# --- ВОССТАНОВЛЕНИЕ ---
perform_restore() {
    if [ -z "$(ls -A $BACKUP_DIR)" ]; then echo -e "${RED}Нет бэкапов!${NC}"; return; fi
    
    echo -e "\n${YELLOW}Доступные бэкапы:${NC}"
    ls -1t "$BACKUP_DIR" | grep ".zip" | head -n 10
    echo "... (показаны последние 10)"
    echo ""
    read -p "Имя файла: " BACKUP_NAME
    FULL_PATH="$BACKUP_DIR/$BACKUP_NAME"
    
    if [ ! -f "$FULL_PATH" ]; then echo -e "${RED}Файл не найден!${NC}"; return; fi

    read -p "Это ПЕРЕЗАПИШЕТ базу данных. Продолжить? [y/N]: " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    TEMP_RESTORE="$INSTALL_DIR/restore_temp"
    mkdir -p "$TEMP_RESTORE"
    unzip -o "$FULL_PATH" -d "$TEMP_RESTORE" > /dev/null
    
    SQL_DUMP=$(find "$TEMP_RESTORE" -name "*.sql" | head -n 1)
    RESTORE_ENV="$TEMP_RESTORE/.env"

    if [ -f "$RESTORE_ENV" ]; then export $(grep -v '^#' "$RESTORE_ENV" | xargs); fi

    echo "Стоп бота..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" stop bot

    echo "Заливка базы..."
    cat "$SQL_DUMP" | docker exec -i vpnmanager_postgres psql -U "${DB_USER}" -d "${DB_NAME}"

    read -p "Восстановить файл .env? [y/N]: " r_env
    if [[ "$r_env" == "y" ]]; then cp "$RESTORE_ENV" "$PROJECT_DIR/.env"; fi

    echo "Старт бота..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" start bot
    rm -rf "$TEMP_RESTORE"
    echo -e "${GREEN}✔ Восстановлено.${NC}"
}

# --- ЛОГИКА ЗАПУСКА ---

if [[ "$1" == "--auto" ]]; then
    perform_backup
    exit 0
fi

CURRENT=$(readlink -f "$0")
TARGET="$INSTALL_DIR/remna-syslab-backup-restore.sh"

if [ "$CURRENT" != "$TARGET" ]; then
    install_script
    exit 0
fi

while true; do
    clear
    echo -e "${GREEN}=== Remna SysLab Backup Manager v3.2 ===${NC}"
    echo "1. 🚀 Бэкап сейчас"
    echo "2. ♻️  Восстановить"
    echo "3. ⏰ Настроить Cron"
    echo "4. ⚙️  Показать настройки"
    echo "5. 🛠  Изменить настройки"
    echo "6. 🔄 Обновить скрипт"
    echo "7. ❌ Удалить менеджер"
    echo "0. Выход"
    read -p "Ваш выбор: " choice

    case $choice in
        1) perform_backup; read -p "Enter..." ;;
        2) perform_restore; read -p "Enter..." ;;
        3) 
           read -p "Cron расписание (напр. '0 3 * * *'): " sch
           sch=${sch:-"0 3 * * *"}
           (crontab -l 2>/dev/null | grep -v "$TARGET"; echo "$sch $TARGET --auto") | crontab -
           echo "Cron обновлен."; read -p "Enter..." ;;
        4) 
           echo -e "\nПроект: $PROJECT_DIR"
           echo "Токен: ${TG_BOT_TOKEN:0:10}..."
           echo "Хранить штук: $MAX_BACKUPS_COUNT"
           read -p "Enter..." ;;
        5) edit_settings; read -p "Enter..." ;;
        6) self_update ;;
        7) 
           read -p "Удалить скрипт? [y/N]: " d
           if [[ "$d" == "y" ]]; then
               crontab -l | grep -v "$TARGET" | crontab -
               rm "$TARGET"; rmdir "$INSTALL_DIR" 2>/dev/null
               echo "Удалено."; exit 0
           fi ;;
        0) exit 0 ;;
    esac
done
