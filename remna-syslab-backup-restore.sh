#!/bin/bash

# ==============================================================================
# REMNA SYSLAB BACKUP & RESTORE TOOL
# Autonomous Backup System for Dockerized VpnManager
# ==============================================================================

# --- КОНФИГУРАЦИЯ (Заполняется автоматически при инсталляции) ---
BOT_TOKEN=""
CHAT_ID=""
TOPIC_ID=""
PROJECT_DIR="" 
INSTALL_DIR="/opt/remna-syslab-backup-restore"
BACKUP_DIR="/opt/remna-syslab-backup-restore/backup"
# ----------------------------------------------------------------

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root (sudo).${NC}"
  exit 1
fi

# Функция сохранения настроек внутрь скрипта (в целевой файл)
save_config() {
    local target_file="$1"
    sed -i "s|^BOT_TOKEN=.*|BOT_TOKEN=\"$BOT_TOKEN\"|" "$target_file"
    sed -i "s|^CHAT_ID=.*|CHAT_ID=\"$CHAT_ID\"|" "$target_file"
    sed -i "s|^TOPIC_ID=.*|TOPIC_ID=\"$TOPIC_ID\"|" "$target_file"
    sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=\"$PROJECT_DIR\"|" "$target_file"
}

# --- ИНСТАЛЛЯТОР ---
install_script() {
    echo -e "${GREEN}=== Установка Remna SysLab Backup Tool ===${NC}"
    
    # 1. Проверяем зависимости
    if ! command -v zip &> /dev/null || ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}Устанавливаю необходимые пакеты (zip, curl)...${NC}"
        apt-get update && apt-get install -y zip curl
    fi

    # 2. Запрос данных
    echo -e "\n${YELLOW}[Настройка путей]${NC}"
    read -p "Укажите путь к проекту VpnManager [/opt/VpnManagerEasy]: " input_dir
    PROJECT_DIR=${input_dir:-/opt/VpnManagerEasy}
    
    if [ ! -d "$PROJECT_DIR" ]; then
        echo -e "${RED}Ошибка: Директория $PROJECT_DIR не найдена!${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}[Настройка Telegram]${NC}"
    read -p "Введите Telegram BOT_TOKEN: " BOT_TOKEN
    read -p "Введите Telegram CHAT_ID: " CHAT_ID
    read -p "Введите TOPIC_ID (оставьте пустым, если не нужно): " TOPIC_ID

    # 3. Создание структуры
    mkdir -p "$BACKUP_DIR"

    # 4. Копирование и настройка
    TARGET_SCRIPT="$INSTALL_DIR/remna-syslab-backup-restore.sh"
    cp "$0" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"
    
    # Сохраняем настройки ВНУТРЬ скопированного файла
    save_config "$TARGET_SCRIPT"

    echo -e "\n${GREEN}✔ Установка завершена!${NC}"
    echo -e "Скрипт находится здесь: ${YELLOW}$TARGET_SCRIPT${NC}"
    echo -e "Запускаю установленную версию...\n"
    
    # Передача управления установленному скрипту
    exec "$TARGET_SCRIPT"
}

# --- ФУНКЦИЯ БЭКАПА ---
perform_backup() {
    # Проверка переменных
    if [ -z "$BOT_TOKEN" ]; then 
        echo -e "${RED}Ошибка: Скрипт не настроен.${NC}"; exit 1
    fi
    
    # Загрузка переменных окружения проекта для доступа к БД
    if [ -f "$PROJECT_DIR/.env" ]; then
        export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
    else
        echo -e "${RED}Ошибка: Файл .env не найден в $PROJECT_DIR${NC}"
        exit 1
    fi
    
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    SQL_FILE="$BACKUP_DIR/db_$TIMESTAMP.sql"
    ZIP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.zip"
    
    # 1. Создание дампа
    echo "Создание дампа базы данных..."
    if ! docker exec vpnmanager_postgres pg_dump -U "${DB_USER}" "${DB_NAME}" > "$SQL_FILE"; then
        echo -e "${RED}Ошибка при создании дампа БД!${NC}"
        rm "$SQL_FILE"
        exit 1
    fi
    
    # 2. Архивирование (SQL + .env)
    echo "Архивация..."
    zip -j "$ZIP_FILE" "$SQL_FILE" "$PROJECT_DIR/.env" > /dev/null
    rm "$SQL_FILE" # Удаляем сырой SQL
    
    # 3. Отправка в Telegram
    echo "Отправка в Telegram..."
    curl -s -F chat_id="$CHAT_ID" -F message_thread_id="$TOPIC_ID" \
         -F document=@"$ZIP_FILE" \
         -F caption="📦 Remna SysLab Backup: $TIMESTAMP" \
         "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" > /dev/null
         
    # 4. Очистка старых бэкапов (оставляем последние 14 дней)
    find "$BACKUP_DIR" -name "backup_*.zip" -type f -mtime +14 -delete
    
    echo -e "${GREEN}✔ Бэкап успешно выполнен и отправлен.${NC}"
}

# --- ФУНКЦИЯ ВОССТАНОВЛЕНИЯ ---
perform_restore() {
    echo -e "\n${YELLOW}=== Восстановление системы ===${NC}"
    
    # Проверка наличия бэкапов
    if [ -z "$(ls -A $BACKUP_DIR)" ]; then
       echo -e "${RED}Папка бэкапов пуста! ($BACKUP_DIR)${NC}"
       return
    fi

    # Выбор файла
    echo "Доступные файлы:"
    ls -1 "$BACKUP_DIR" | grep ".zip"
    echo ""
    read -p "Введите имя файла (полностью, например backup_2026...zip): " BACKUP_NAME
    
    FULL_PATH="$BACKUP_DIR/$BACKUP_NAME"
    
    if [ ! -f "$FULL_PATH" ]; then
        echo -e "${RED}Файл не найден!${NC}"
        return
    fi

    echo -e "${YELLOW}ВНИМАНИЕ! Текущая база данных будет перезаписана!${NC}"
    read -p "Вы уверены? [y/N]: " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    # Распаковка во временную папку
    TEMP_RESTORE="$INSTALL_DIR/restore_temp"
    mkdir -p "$TEMP_RESTORE"
    unzip -o "$FULL_PATH" -d "$TEMP_RESTORE" > /dev/null
    
    # Получение имени SQL файла
    SQL_DUMP=$(find "$TEMP_RESTORE" -name "*.sql" | head -n 1)
    RESTORE_ENV="$TEMP_RESTORE/.env"

    # Загрузка конфига из БЭКАПА для подключения к БД
    if [ -f "$RESTORE_ENV" ]; then
        export $(grep -v '^#' "$RESTORE_ENV" | xargs)
    fi

    # Остановка бота
    echo "Останавливаю бота..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" stop bot

    # Заливка базы
    echo "Восстанавливаю базу данных..."
    if cat "$SQL_DUMP" | docker exec -i vpnmanager_postgres psql -U "${DB_USER}" -d "${DB_NAME}"; then
        echo -e "${GREEN}✔ База данных восстановлена.${NC}"
    else
        echo -e "${RED}Ошибка восстановления БД!${NC}"
    fi

    # Восстановление .env
    read -p "Хотите восстановить файл .env из бэкапа? [y/N]: " restore_env_q
    if [[ "$restore_env_q" == "y" ]]; then
        cp "$RESTORE_ENV" "$PROJECT_DIR/.env"
        echo -e "${GREEN}✔ Файл .env восстановлен.${NC}"
    fi

    # Запуск бота
    echo "Запускаю бота..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" start bot

    # Уборка
    rm -rf "$TEMP_RESTORE"
    echo -e "${GREEN}=== Восстановление завершено ===${NC}"
}

# --- ГЛАВНАЯ ЛОГИКА ---

# 1. Если запущен с флагом --auto (для Cron)
if [[ "$1" == "--auto" ]]; then
    perform_backup
    exit 0
fi

# 2. Если запущен не из папки установки -> запускаем инсталлятор
CURRENT_SCRIPT_PATH=$(readlink -f "$0")
TARGET_SCRIPT_PATH="$INSTALL_DIR/remna-syslab-backup-restore.sh"

if [ "$CURRENT_SCRIPT_PATH" != "$TARGET_SCRIPT_PATH" ]; then
    install_script
    exit 0
fi

# 3. Интерактивное меню (если скрипт уже установлен)
while true; do
    clear
    echo -e "${GREEN}=== Remna SysLab Backup Manager ===${NC}"
    echo -e "Рабочая директория: $INSTALL_DIR"
    echo -e "Директория проекта: $PROJECT_DIR"
    echo "-----------------------------------"
    echo "1. 🚀 Выполнить бэкап сейчас"
    echo "2. ♻️  Восстановить из резервной копии"
    echo "3. ⏰ Настроить авто-бэкап (Cron)"
    echo "4. ⚙️  Показать текущие настройки"
    echo "5. ❌ Удалить менеджер и настройки"
    echo "0. Выход"
    echo "-----------------------------------"
    read -p "Ваш выбор: " choice

    case $choice in
        1)
            perform_backup
            read -p "Нажмите Enter для продолжения..."
            ;;
        2)
            perform_restore
            read -p "Нажмите Enter для продолжения..."
            ;;
        3)
            read -p "Введите расписание Cron (например '0 3 * * *' для 3:00 ночи): " CRON_SCHEDULE
            CRON_SCHEDULE=${CRON_SCHEDULE:-"0 3 * * *"}
            
            # Удаляем старую задачу и добавляем новую
            (crontab -l 2>/dev/null | grep -v "$TARGET_SCRIPT_PATH"; echo "$CRON_SCHEDULE $TARGET_SCRIPT_PATH --auto") | crontab -
            echo -e "${GREEN}✔ Расписание обновлено!${NC}"
            read -p "Нажмите Enter для продолжения..."
            ;;
        4)
            echo -e "\nBot Token: ${BOT_TOKEN:0:10}..."
            echo "Chat ID: $CHAT_ID"
            echo "Topic ID: $TOPIC_ID"
            read -p "Нажмите Enter..."
            ;;
        5)
            read -p "Вы уверены? Это удалит скрипт и расписание (бэкапы останутся). [y/N]: " del_conf
            if [[ "$del_conf" == "y" ]]; then
                crontab -l | grep -v "$TARGET_SCRIPT_PATH" | crontab -
                rm "$TARGET_SCRIPT_PATH"
                rmdir "$INSTALL_DIR" 2>/dev/null # Удалит только если пустая
                echo "Скрипт удален."
                exit 0
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Неверный выбор"
            sleep 1
            ;;
    esac
done
