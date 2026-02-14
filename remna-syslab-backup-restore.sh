#!/bin/bash

# ==============================================================================
# REMNA SYSLAB BACKUP & RESTORE TOOL v2.0
# Autonomous Backup System for Dockerized VpnManager
# ==============================================================================

# --- КОНФИГУРАЦИЯ (Заполняется автоматически) ---
TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_TOPIC_ID=""
PROJECT_DIR="" 
INSTALL_DIR="/opt/remna-syslab-backup-restore"
BACKUP_DIR="/opt/remna-syslab-backup-restore/backup"
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
    # Используем уникальные имена переменных, чтобы избежать конфликта с .env
    sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"$TG_BOT_TOKEN\"|" "$target_file"
    sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$TG_CHAT_ID\"|" "$target_file"
    sed -i "s|^TG_TOPIC_ID=.*|TG_TOPIC_ID=\"$TG_TOPIC_ID\"|" "$target_file"
    sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=\"$PROJECT_DIR\"|" "$target_file"
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

    mkdir -p "$BACKUP_DIR"

    TARGET_SCRIPT="$INSTALL_DIR/remna-syslab-backup-restore.sh"
    # Копируем текущий скрипт
    cp "$0" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"
    
    # Сохраняем переменные в целевой файл
    save_config "$TARGET_SCRIPT"

    echo -e "\n${GREEN}✔ Установка завершена! Запускаю...${NC}\n"
    exec "$TARGET_SCRIPT"
}

# --- РЕДАКТОР НАСТРОЕК ---
edit_settings() {
    echo -e "\n${YELLOW}=== Редактирование настроек ===${NC}"
    echo "Нажмите Enter, чтобы оставить текущее значение."
    
    read -p "Путь к проекту [$PROJECT_DIR]: " new_dir
    PROJECT_DIR=${new_dir:-$PROJECT_DIR}
    
    read -p "Telegram Token [${TG_BOT_TOKEN:0:10}...]: " new_token
    TG_BOT_TOKEN=${new_token:-$TG_BOT_TOKEN}
    
    read -p "Chat ID [$TG_CHAT_ID]: " new_chat
    TG_CHAT_ID=${new_chat:-$TG_CHAT_ID}
    
    read -p "Topic ID [$TG_TOPIC_ID]: " new_topic
    TG_TOPIC_ID=${new_topic:-$TG_TOPIC_ID}
    
    save_config "$0"
    echo -e "${GREEN}✔ Настройки обновлены!${NC}"
}

# --- БЭКАП ---
perform_backup() {
    if [ -z "$TG_BOT_TOKEN" ]; then echo -e "${RED}Не настроен токен!${NC}"; exit 1; fi
    
    # Загружаем .env для доступа к БД
    # Важно: переменные из .env могут перезаписать локальные,
    # но так как мы используем TG_BOT_TOKEN, конфликта не будет.
    if [ -f "$PROJECT_DIR/.env" ]; then
        export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
    else
        echo -e "${RED}.env не найден!${NC}"; exit 1
    fi
    
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    SQL_FILE="$BACKUP_DIR/db_$TIMESTAMP.sql"
    ZIP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.zip"
    
    echo "Дамп базы..."
    if ! docker exec vpnmanager_postgres pg_dump -U "${DB_USER}" "${DB_NAME}" > "$SQL_FILE"; then
        echo -e "${RED}Ошибка дампа БД!${NC}"; rm "$SQL_FILE"; exit 1
    fi
    
    echo "Архивация..."
    zip -j "$ZIP_FILE" "$SQL_FILE" "$PROJECT_DIR/.env" > /dev/null
    rm "$SQL_FILE"
    
    echo "Отправка в Telegram..."
    curl -s -F chat_id="$TG_CHAT_ID" -F message_thread_id="$TG_TOPIC_ID" \
         -F document=@"$ZIP_FILE" \
         -F caption="📦 Remna Backup: $TIMESTAMP" \
         "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
         
    find "$BACKUP_DIR" -name "backup_*.zip" -type f -mtime +14 -delete
    echo -e "${GREEN}✔ Готово.${NC}"
}

# --- ВОССТАНОВЛЕНИЕ ---
perform_restore() {
    if [ -z "$(ls -A $BACKUP_DIR)" ]; then echo -e "${RED}Нет бэкапов!${NC}"; return; fi
    
    echo -e "\n${YELLOW}Доступные бэкапы:${NC}"
    ls -1 "$BACKUP_DIR" | grep ".zip"
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

    # Берем данные для БД из восстанавливаемого .env
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
    echo -e "${GREEN}=== Remna SysLab Backup Manager ===${NC}"
    echo "1. 🚀 Бэкап сейчас"
    echo "2. ♻️  Восстановить"
    echo "3. ⏰ Настроить Cron"
    echo "4. ⚙️  Показать текущие настройки"
    echo "5. 🛠  Изменить настройки"
    echo "6. ❌ Удалить менеджер"
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
           echo "Чат: $TG_CHAT_ID | Топик: $TG_TOPIC_ID"
           read -p "Enter..." ;;
        5) edit_settings; read -p "Enter..." ;;
        6) 
           read -p "Удалить скрипт? [y/N]: " d
           if [[ "$d" == "y" ]]; then
               crontab -l | grep -v "$TARGET" | crontab -
               rm "$TARGET"; rmdir "$INSTALL_DIR" 2>/dev/null
               echo "Удалено."; exit 0
           fi ;;
        0) exit 0 ;;
    esac
done
