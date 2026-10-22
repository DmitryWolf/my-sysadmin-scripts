# Мониторинг ресурсов

Bash-скрипт каждые 5 секунд дописывает временную метку и вывод `free -h`, `df -h`, `uptime` в `monitor.log`.

Проект выполняется на постоянной Multipass-VM `sysadmin-host` с Ubuntu 22.04. ДЗ1 — скрипт и Git, ДЗ2 — контейнер, RAID/LVM, Nginx, TLS и systemd. Выбрана дорожка «База».

## Скрипт без контейнера

```bash
./script.sh
```

Остановка — Ctrl+C. Повторный запуск дописывает существующий лог. Другой путь можно задать переменной `MONITOR_LOG_FILE`; интервал остаётся константой 5 секунд. Реальный пример из ДЗ1 сохранён в `sample_output.txt`.

## Схема

```text
WSL / браузер → HTTPS:443 → Nginx в VM → localhost:8080 → контейнер
                                                           ├─ script.sh
                                                           └─ Python HTTP-сервер
                                                                  │
                                               /var/www/monitor.log
                                                                  │ bind mount
                                               /mnt/logs/my-app/monitor.log
```

В контейнере используются UID/GID 1000. Если мониторинг или HTTP-сервер завершается, контейнер тоже завершается; службу перезапускает systemd.

## Установка на учебную VM

Все следующие команды выполняются **внутри VM**, из каталога репозитория. Нужны права sudo. Они рассчитаны на выделенную учебную машину без другого сайта Nginx и без чужих `my-app`, `vg_data`, `/mnt/raid`, `/mnt/logs`.

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 docker-buildx mdadm lvm2 nginx openssl curl
sudo usermod -aG docker "$USER"
```

После добавления в группу Docker выйдите из SSH и подключитесь снова.

```bash
cd ~/my-sysadmin-scripts
sudo bash deploy/storage.sh init
docker build -t my-script .
docker compose up -d
curl --fail --retry 10 --retry-all-errors --retry-delay 1 --max-time 5 http://127.0.0.1:8080/monitor.log
docker compose stop
sudo bash deploy/install-service.sh
```

Первый запрос выполняйте после появления первой записи в логе. Установщик службы сам ожидает готовности HTTPS. Он сохраняет существующие данные и сертификат при повторном запуске.

## Хранилище

| Файлы-диски | Устройство | Точка монтирования | Назначение |
|---|---|---|---|
| `/mnt/raid-lab/disk1.img`, `disk2.img`, по 512 МиБ | RAID 1 | `/mnt/raid` | Учебное зеркалирование |
| `/mnt/raid-lab/disk3.img`, 512 МиБ | `vg_data/lv_logs`, 200 МиБ | `/mnt/logs` | Сохранение `my-app/monitor.log` |

RAID и LVM здесь собраны отдельно, как в методичке. RAID дублирует блоки, LVM позволяет управлять объёмом. Поскольку все образы находятся на одном диске VM, это демонстрация механизмов, а не защита от потери физического накопителя.

`init` создаёт только отсутствующие образы. Если обнаружены старые образы без файла состояния, скрипт останавливается и ничего не форматирует. UUID компонентов хранятся в `/etc/course-storage.conf` на VM.

После перезагрузки `course-storage.service` повторно подключает образы к свободным loop-устройствам, собирает существующий RAID, активирует LVM и монтирует тома. Форматирование при этом не выполняется. Приложение запускается после восстановления хранилища.

После автоматической сборки имя массива может измениться с `/dev/md0` на `/dev/md127`. Скрипт находит его по сохранённому UUID; точка монтирования `/mnt/raid` остаётся той же.

```bash
sudo course-storage status
sudo course-storage start   # подключить существующие тома вручную, если нужно
```

## Сервис и проверки

HTTP перенаправляется на HTTPS. Nginx отдаёт результат мониторинга через прокси; порт 8080 доступен только внутри VM. Сертификат самоподписанный, поэтому учебные проверки используют `curl -k`. Закрытый ключ хранится только в `/etc/ssl/private/my-app.key` на VM.

```bash
sudo systemctl status my-app --no-pager
systemctl is-enabled my-app
curl -I http://127.0.0.1:8080/monitor.log
curl -kI https://127.0.0.1/
curl -k https://127.0.0.1/monitor.log
bash deploy/check.sh
```

Из WSL замените `127.0.0.1` на текущий IPv4 из `multipass info sysadmin-host`. Ожидается HTTP 200 и содержимое лога. Предупреждение браузера о самоподписанном сертификате ожидаемо.

```bash
sudo systemctl stop my-app
sudo systemctl start my-app
sudo journalctl -u my-app -n 25 --no-pager
sudo tail -n 10 /var/log/nginx/access.log
```

После установки управляйте приложением через systemd. Для проверки Compose сначала остановите `my-app.service`, затем запускайте Compose; перед возвращением к systemd остановите контейнер через `docker compose stop`. Отдельный перезапуск Docker может остановить зависимую службу — после него запустите `sudo systemctl start my-app`.

Проверено на VM: повторная настройка хранилища сохраняет контрольные файлы; остановка HTTP-процесса приводит к автоматическому перезапуску приложения; после перезагрузки VM тома монтируются и сервис запускается автоматически. Прежнее содержимое `monitor.log` сохранено, новые замеры добавляются. В контейнере время записывается в UTC (`+0000`), на VM — в MSK (`+0300`).

## Файлы проекта

- `script.sh`, `sample_output.txt` — мониторинг и пример вывода ДЗ1.
- `Dockerfile`, `container-entrypoint.sh`, `docker-compose.yml` — образ и запуск контейнера.
- `deploy/storage.sh`, `deploy/course-storage.service` — создание и восстановление учебного хранилища.
- `deploy/nginx.conf`, `deploy/my-app.service`, `deploy/install-service.sh` — HTTPS и управление приложением.
- `deploy/check.sh` — проверка хранилища, HTTPS, автозапуска, роста лога и одного запроса в обоих журналах.
