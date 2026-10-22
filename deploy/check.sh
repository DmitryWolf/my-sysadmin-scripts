#!/usr/bin/env bash
# Проверка установленного проекта внутри VM. Ничего не создаёт и не форматирует.
set -euo pipefail
run() {
    printf '\n$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
}
run date --iso-8601=seconds
run hostname
run docker ps -a --filter name=my-app
run docker image inspect my-script:latest --format '{{.Id}}'
run sudo /usr/local/sbin/course-storage status
run sudo nginx -t
run curl -sSI --max-time 10 http://127.0.0.1/monitor.log
redirect=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/monitor.log)
[[ $redirect == 301 ]]
run curl -kfsSI --max-time 10 https://127.0.0.1/monitor.log
run systemctl is-enabled my-app.service
run systemctl is-active my-app.service
run systemctl status my-app.service --no-pager --full

check_dir=$(mktemp -d)
trap 'rm -rf -- "$check_dir"' EXIT
curl -kfsS --max-time 10 https://127.0.0.1/monitor.log -o "$check_dir/before"
[[ -s "$check_dir/before" ]]
sleep 6
curl -kfsS --max-time 10 https://127.0.0.1/monitor.log -o "$check_dir/after"
before_bytes=$(wc -c < "$check_dir/before")
after_bytes=$(wc -c < "$check_dir/after")
[[ $after_bytes -gt $before_bytes ]]
cmp -n "$before_bytes" "$check_dir/before" "$check_dir/after"
printf '\nЛог дописывается: %s -> %s байт за 6 секунд, прежнее содержимое сохранено.\n' \
    "$before_bytes" "$after_bytes"
run tail -n 25 "$check_dir/after"

request_id="hw2-check-$(date +%s)"
run curl -kfsSI --max-time 10 "https://127.0.0.1/monitor.log?check=$request_id"
run sudo journalctl -u my-app.service -n 25 --no-pager
run sudo tail -n 10 /var/log/nginx/access.log
sudo journalctl -u my-app.service --since '2 minutes ago' --no-pager | grep -F "$request_id"
sudo grep -F "$request_id" /var/log/nginx/access.log
printf '\nВсе проверки пройдены.\n'
