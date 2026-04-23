#!/bin/bash

# =================================================
# Положи файл lywsd03mmc.py рядом с этим скриптом.
# Запусти: chmod +x имя_скрипта.sh && ./имя_скрипта.sh.
# Если скрипт скажет, что изменил config.txt, 
# обязательно согласись на перезагрузку или сделай её сам, 
# иначе Bluetooth не "увидит" датчик.
# =================================================

# --- НАСТРОЙКИ ---
CONFIG_TXT="/boot/firmware/config.txt"
RESOLV_CONF="/etc/resolv.conf"
DNS_ENTRY="nameserver 8.8.8.8"
KLIPPY_ENV="$HOME/klippy-env"
PRINTER_CFG="$HOME/printer_data/config/printer.cfg"
TEMP_CFG="$HOME/klipper/klippy/extras/temperature_sensors.cfg"
EXTRAS_DIR="$HOME/klipper/klippy/extras/"
SOURCE_PY="lywsd03mmc.py"
ANCHOR="#\*# <---------------------- SAVE_CONFIG ---------------------->"

echo "=== Запуск процесса автоматической настройки ==="

# 1. Проверка аппаратной части Bluetooth (config.txt)
echo "Шаг 1: Проверка аппаратной настройки Bluetooth..."
[ ! -f "$CONFIG_TXT" ] && CONFIG_TXT="/boot/config.txt"

if grep -q "dtoverlay=disable-bt" "$CONFIG_TXT"; then
    echo "Bluetooth отключен в $CONFIG_TXT. Исправляю на miniuart-bt..."
    sudo sed -i "s/dtoverlay=disable-bt/dtoverlay=miniuart-bt/g" "$CONFIG_TXT"
    echo "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА системы для активации Bluetooth."
    read -p "Перезагрузить сейчас? (y/n): " REBOOT_NOW
    if [[ "$REBOOT_NOW" == "y" || "$REBOOT_NOW" == "Y" ]]; then
        sudo reboot
    else
        echo "Пожалуйста, перезагрузитесь позже вручную, иначе сканирование не сработает."
    fi
fi

# 2. Установка системных пакетов
echo "Шаг 2: Установка системных пакетов..."
sudo apt update
sudo apt install python3-pip libglib2.0-dev bluez -y

# 3. Настройка DNS
echo "Шаг 3: Проверка DNS..."
if ! grep -qxF "$DNS_ENTRY" "$RESOLV_CONF"; then
    echo "$DNS_ENTRY" | sudo tee -a "$RESOLV_CONF" > /dev/null
    sudo systemctl restart networking
else
    echo "DNS уже настроен."
fi

# 4. Установка Python-библиотек
echo "Шаг 4: Установка расширений Python..."
if [ -d "$KLIPPY_ENV" ]; then
    $KLIPPY_ENV/bin/pip install requests bleak bthome-ble home-assistant-bluetooth
else
    echo "Предупреждение: Окружение $KLIPPY_ENV не найдено!"
fi

# 5. Проверка и запуск Bluetooth службы
echo "Шаг 5: Запуск службы Bluetooth..."
if [ "$(systemctl is-active bluetooth)" != "active" ]; then
    sudo systemctl enable --now bluetooth
    sleep 2
fi

# 6. Поиск MAC-адреса датчика
echo "Шаг 6: Поиск датчика..."
DEFAULT_NAME="ATC_8115E5"
read -p "Введите имя датчика (по умолчанию $DEFAULT_NAME): " SENSOR_NAME
SENSOR_NAME=${SENSOR_NAME:-$DEFAULT_NAME}

echo "Сканирую эфир (10 секунд)..."
MAC_ADDRESS=$(sudo timeout 10s hcitool lescan | grep "$SENSOR_NAME" | awk '{print $1}' | head -n 1)

if [ -z "$MAC_ADDRESS" ]; then
    echo "ОШИБКА: Датчик '$SENSOR_NAME' не найден. Возможно, нужен reboot или датчик далеко."
    exit 1
fi
echo "Найден адрес: $MAC_ADDRESS"

# 7. Настройка temperature_sensors.cfg
echo "Шаг 7: Настройка модуля в $TEMP_CFG..."
if [ -f "$TEMP_CFG" ]; then
    if ! grep -q "\[lywsd03mmc\]" "$TEMP_CFG"; then
        sed -i "/\[temperature_combined\]/a # Загружаем модуль LYWSD03MMC\n[lywsd03mmc]" "$TEMP_CFG"
    fi
fi

# 8. Настройка printer.cfg (Respond, Sensor, Macro)
echo "Шаг 8: Обновление конфигурации принтера..."

# [respond]
if ! grep -q "\[respond\]" "$PRINTER_CFG"; then
    sed -i "/$ANCHOR/i [respond]\n" "$PRINTER_CFG"
fi

# [temperature_sensor dryer]
if ! grep -q "\[temperature_sensor dryer\]" "$PRINTER_CFG"; then
    SENSOR_BLOCK="[temperature_sensor dryer]\nsensor_type: LYWSD03MMC\naddress: $MAC_ADDRESS\n"
    sed -i "/$ANCHOR/i $SENSOR_BLOCK" "$PRINTER_CFG"
fi

# [gcode_macro CHECK_DRYER]
if ! grep -q "\[gcode_macro CHECK_DRYER\]" "$PRINTER_CFG"; then
    read -r -d '' MACRO_BLOCK << 'EOF'
[gcode_macro CHECK_DRYER]
gcode:
    {% set sensor = printer["temperature_sensor dryer"] %}
    { action_respond_info("ОТЧЕТ О СУШИЛКЕ ФИЛАМЕНТА:
    Температура: %.2f C
    Влажность: %.1f %%
    Батарея: %d %%" % (
    sensor.temperature,
    sensor.humidity,
    sensor.battery)) }

EOF
    sed -i "/$ANCHOR/i $MACRO_BLOCK" "$PRINTER_CFG"
fi

# 9. Копирование файла модуля
echo "Шаг 9: Установка файла модуля lywsd03mmc.py..."
if [ -f "$SOURCE_PY" ]; then
    cp "$SOURCE_PY" "$EXTRAS_DIR"
    echo "Файл скопирован в $EXTRAS_DIR"
else
    echo "ОШИБКА: Файл $SOURCE_PY не найден в папке со скриптом!"
fi

# 10. Финал
echo "Перезагрузка Klipper..."
sudo systemctl restart klipper

echo "=== Настройка завершена успешно! ==="
