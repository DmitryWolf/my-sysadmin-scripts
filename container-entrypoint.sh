#!/usr/bin/env bash

# Контейнер работает, пока живы и мониторинг, и HTTP-сервер.
pids=()

cleanup() {
    trap '' TERM INT
    if ((${#pids[@]})); then
        kill -TERM "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" 2>/dev/null || true
    fi
}

stop() {
    cleanup
    exit 0
}

trap stop TERM INT

/usr/local/bin/script.sh &
pids+=("$!")
python3 -u -m http.server 8080 --bind 0.0.0.0 --directory /var/www &
pids+=("$!")

# Даже успешное раннее завершение одного процесса требует перезапуска.
if wait -n "${pids[@]}"; then
    status=1
else
    status=$?
fi
printf 'Один из процессов завершился. Контейнер остановлен, код: %s.\n' "$status" >&2
cleanup
exit "$status"
