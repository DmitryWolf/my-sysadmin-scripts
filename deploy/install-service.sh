#!/usr/bin/env bash
# Запускать через sudo внутри учебной VM после создания хранилища.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Запустите через sudo.' >&2; exit 1; }
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"

install -m 0755 deploy/storage.sh /usr/local/sbin/course-storage
install -m 0644 deploy/course-storage.service /etc/systemd/system/course-storage.service
install -m 0644 deploy/my-app.service /etc/systemd/system/my-app.service
systemctl daemon-reload
systemctl enable --now course-storage.service
# RemainAfterExit не заменяет проверку фактического состояния при повторном запуске.
/usr/local/sbin/course-storage start

if [[ -e /etc/ssl/private/my-app.key || -e /etc/ssl/certs/my-app.crt ]]; then
    [[ -s /etc/ssl/private/my-app.key && -s /etc/ssl/certs/my-app.crt ]] || {
        echo 'Неполная пара TLS-ключа и сертификата; проверьте существующие файлы.' >&2
        exit 1
    }
else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/my-app.key \
        -out /etc/ssl/certs/my-app.crt \
        -subj '/CN=my-app.local' \
        -addext 'subjectAltName=DNS:my-app.local,DNS:localhost,IP:127.0.0.1'
fi
chmod 0600 /etc/ssl/private/my-app.key
install -m 0644 deploy/nginx.conf /etc/nginx/sites-available/my-app
ln -sfn /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/my-app
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    unlink /etc/nginx/sites-enabled/default
fi
nginx -t

docker compose build
# Останавливается только служба данного проекта. Compose сохраняет bind-mounted лог.
if systemctl is-active --quiet my-app.service; then
    systemctl stop my-app.service
fi
docker compose stop app
docker compose create app
systemctl enable --now docker nginx my-app.service
systemctl reload nginx

ready=no
for attempt in {1..30}; do
    if curl -kfsS --max-time 2 https://127.0.0.1/monitor.log -o /dev/null 2>/dev/null; then
        ready=yes
        break
    fi
    sleep 1
done
[[ $ready == yes ]] || { echo 'Сервис не готов. Проверьте journalctl -u my-app.' >&2; exit 1; }
printf 'Сервис готов: HTTPS /monitor.log, systemd и хранилище.\n'
systemctl is-enabled my-app.service
systemctl is-active my-app.service
