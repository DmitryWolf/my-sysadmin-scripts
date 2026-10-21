#!/usr/bin/env bash

INTERVAL=5
LOG_FILE="monitor.log"

printf 'Мониторинг запущен. Лог: %s. Для остановки нажмите Ctrl+C.\n' "$LOG_FILE"

while true; do
    {
        date '+=== %Y-%m-%d %H:%M:%S %z ==='
        printf '\nПамять:\n'
        free -h
        printf '\nДиски:\n'
        df -h
        printf '\nНагрузка:\n'
        uptime
        printf '\n'
    } >> "$LOG_FILE"

    sleep "$INTERVAL"
done
