#!/usr/bin/env bash

# Интервал задан константой: скрипт не запрашивает ввод пользователя.
readonly INTERVAL=5
LOG_FILE="${MONITOR_LOG_FILE:-monitor.log}"

fail() {
    printf 'Ошибка: %s\n' "$1" >&2
    exit 1
}

for tool in date free df uptime sleep; do
    command -v "$tool" >/dev/null 2>&1 || fail "Не найдена команда: $tool"
done

# Проверяем открытие лога для дозаписи. Содержимое не стирается.
if ! : >> "$LOG_FILE"; then
    fail "Не удалось открыть лог для записи: $LOG_FILE"
fi

trap 'printf "\nМониторинг остановлен.\n"; exit 130' INT
trap 'printf "\nМониторинг остановлен.\n"; exit 143' TERM

write_snapshot() {
    # && останавливает цепочку, если одна из команд завершилась с ошибкой.
    date '+=== %Y-%m-%d %H:%M:%S %z ===' &&
    printf '\nПамять:\n' &&
    free -h &&
    printf '\nДиски:\n' &&
    df -h &&
    printf '\nНагрузка:\n' &&
    uptime &&
    printf '\n'
}

printf 'Мониторинг запущен. Лог: %s. Интервал: %s с. Остановка: Ctrl+C.\n' \
    "$LOG_FILE" "$INTERVAL"

while true; do
    if ! write_snapshot >> "$LOG_FILE"; then
        fail "Не удалось собрать или записать показатели в лог: $LOG_FILE"
    fi

    sleep "$INTERVAL" || fail "Не удалось выдержать интервал между замерами"
done
