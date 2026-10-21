#!/usr/bin/env bash
# init создаёт новые диски; start только подключает уже существующие данные.
set -Eeuo pipefail
umask 077

readonly IMAGE_DIR=/mnt/raid-lab
readonly STATE=/etc/course-storage.conf
readonly VG=vg_data LV=lv_logs
readonly LV_DEVICE=/dev/vg_data/lv_logs
readonly IMAGE_BYTES=536870912

fail() { printf 'Ошибка хранилища: %s\n' "$*" >&2; exit 1; }
trap 'printf "Ошибка хранилища на строке %s. Существующие диски сохранены.\n" "$LINENO" >&2' ERR

[[ $EUID -eq 0 ]] || fail 'Запустите через sudo внутри учебной VM.'
[[ $# -eq 1 && $1 =~ ^(init|start|status)$ ]] || fail 'Использование: course-storage init|start|status'
for tool in losetup mdadm pvs vgs lvs pvcreate vgcreate lvcreate vgchange \
    blkid mkfs.ext4 findmnt mount mountpoint lsblk udevadm flock; do
    command -v "$tool" >/dev/null || fail "Не найдена команда: $tool"
done
exec 9>/run/lock/course-storage.lock
flock -n 9 || fail 'Уже выполняется другая операция с учебным хранилищем.'
# LVM-команды ниже закрывают у себя FD 9; родитель сохраняет блокировку.

check_directory() {
    local directory=$1 permissions
    [[ ! -L $directory ]] || fail "$directory не должен быть символической ссылкой."
    [[ -d $directory ]] || fail "Нет каталога $directory."
    [[ $(stat -c %u "$directory") == 0 ]] || fail "$directory должен принадлежать root."
    permissions=$(stat -c %a "$directory")
    (( (8#$permissions & 022) == 0 )) || fail "$directory доступен для записи не только root."
}

load_state() {
    [[ -f $STATE && ! -L $STATE ]] || fail "Нет $STATE. Для первой установки используйте init."
    [[ $(stat -c '%u:%a' "$STATE") == 0:600 ]] || fail "$STATE должен принадлежать root и иметь права 600."
    # Файл создаётся только этим скриптом в /etc с правами root:600.
    source "$STATE"
    local name
    for name in RAID_UUID RAID_FS_UUID PV_UUID VG_UUID LV_UUID LOGS_FS_UUID; do
        [[ ${!name:-} =~ ^[[:alnum:]:-]+$ ]] || fail "Некорректное значение $name в $STATE."
    done
}

attach_image() {
    local file=$1 devices loop offset limit
    [[ -f $file && ! -L $file ]] || fail "Нет обычного файла-диска $file."
    [[ $(stat -c '%u:%a:%h:%s' "$file") == "0:600:1:$IMAGE_BYTES" ]] ||
        fail "У $file изменились владелец, права, число ссылок или размер."
    devices=$(losetup --list --raw --noheadings --output NAME --associated "$file")
    if [[ -z $devices ]]; then
        loop=$(losetup --find --show "$file")
    else
        [[ $devices != *$'\n'* ]] || fail "Файл $file подключён к нескольким loop-устройствам."
        loop=$devices
    fi
    read -r offset limit < <(losetup --list --noheadings --output OFFSET,SIZELIMIT "$loop")
    [[ $offset == 0 && $limit == 0 ]] || fail "У $loop нестандартные offset/sizelimit."
    printf '%s\n' "$loop"
}

attach_images() {
    check_directory "$IMAGE_DIR"
    LOOP1=$(attach_image "$IMAGE_DIR/disk1.img")
    LOOP2=$(attach_image "$IMAGE_DIR/disk2.img")
    LOOP3=$(attach_image "$IMAGE_DIR/disk3.img")
    udevadm settle --timeout=30
}

md_uuid() {
    mdadm "$1" --export "$2" | awk -F= '$1 == "MD_UUID" {print $2}'
}

find_raid() {
    local directory device uuid
    RAID_DEVICE=
    for directory in /sys/block/md*/md; do
        [[ -d $directory ]] || continue
        device=/dev/$(basename "$(dirname "$directory")")
        uuid=$(md_uuid --detail "$device") || fail "Не удалось прочитать состояние $device."
        if [[ $uuid == "$RAID_UUID" ]]; then
            [[ -z $RAID_DEVICE ]] || fail 'Обнаружено несколько массивов с нашим UUID.'
            RAID_DEVICE=$device
        fi
    done
}

check_raid_members() {
    local base member count=0
    base=/sys/class/block/$(basename "$RAID_DEVICE")
    [[ $(cat "$base/md/level") == raid1 && $(cat "$base/md/raid_disks") == 2 ]] ||
        fail 'Ожидался RAID 1 из двух устройств.'
    [[ $(cat "$base/md/degraded") == 0 ]] || fail 'RAID работает в деградированном состоянии.'
    for member in "$base"/slaves/*; do
        [[ -e $member ]] || continue
        [[ /dev/$(basename "$member") == "$LOOP1" || /dev/$(basename "$member") == "$LOOP2" ]] ||
            fail 'В RAID обнаружено постороннее устройство.'
        count=$((count + 1))
    done
    [[ $count == 2 ]] || fail 'В RAID должны присутствовать оба учебных loop-устройства.'
}

mount_checked() {
    local device=$1 directory=$2 expected_uuid=$3 source_number device_number
    [[ $(blkid -s UUID -o value "$device") == "$expected_uuid" ]] || fail "Не совпал UUID файловой системы $device."
    [[ $(blkid -s TYPE -o value "$device") == ext4 ]] || fail "Ожидалась ext4 на $device."
    [[ ! -L $directory ]] || fail "$directory не должен быть ссылкой."
    if mountpoint -q "$directory"; then
        source_number=$(findmnt --raw --noheadings --output MAJ:MIN --mountpoint "$directory")
        device_number=$(lsblk --raw --nodeps --noheadings --output MAJ:MIN "$device")
        [[ $source_number == "$device_number" ]] || fail "$directory занят другим устройством."
    else
        mkdir -p "$directory"
        check_directory "$directory"
        [[ -z $(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail "$directory содержит файлы вне тома."
        mount -t ext4 "$device" "$directory"
    fi
}

start_storage() {
    load_state
    attach_images
    [[ $(md_uuid --examine "$LOOP1") == "$RAID_UUID" && $(md_uuid --examine "$LOOP2") == "$RAID_UUID" ]] ||
        fail 'UUID RAID на файлах-дисках не соответствует сохранённому.'
    find_raid
    if [[ -z $RAID_DEVICE ]]; then
        [[ ! -e /sys/class/block/md0 && ! -e /dev/md0 ]] || fail '/dev/md0 уже занят; автоматическая перезапись запрещена.'
        mdadm --assemble /dev/md0 --uuid="$RAID_UUID" "$LOOP1" "$LOOP2"
        udevadm settle --timeout=30
        find_raid
        [[ -n $RAID_DEVICE ]] || fail 'После сборки массив с нашим UUID не найден.'
    fi
    check_raid_members
    local actual_pv actual_vg actual_name
    read -r actual_pv actual_vg actual_name < <(pvs --noheadings -o pv_uuid,vg_uuid,vg_name "$LOOP3" 9>&-)
    [[ $actual_pv == "$PV_UUID" && $actual_vg == "$VG_UUID" && $actual_name == "$VG" ]] ||
        fail 'LVM на третьем файле-диске не соответствует сохранённым UUID.'
    [[ $(vgs --noheadings -o pv_count "$VG" 9>&- | xargs) == 1 ]] || fail 'В vg_data обнаружены дополнительные PV.'
    [[ $(lvs --noheadings -o lv_uuid "$VG/$LV" 9>&- | xargs) == "$LV_UUID" ]] || fail 'Не совпал UUID lv_logs.'
    vgchange --activate y "$VG" 9>&-
    udevadm settle --timeout=30
    mount_checked "$RAID_DEVICE" /mnt/raid "$RAID_FS_UUID"
    mount_checked "$LV_DEVICE" /mnt/logs "$LOGS_FS_UUID"
    [[ ! -L /mnt/logs/my-app ]] || fail '/mnt/logs/my-app не должен быть ссылкой.'
    mkdir -p /mnt/logs/my-app
    chown 1000:1000 /mnt/logs/my-app
    chmod 0755 /mnt/logs/my-app
    printf 'RAID: %s -> /mnt/raid; LVM: %s -> /mnt/logs.\n' "$RAID_DEVICE" "$LV_DEVICE"
}

init_storage() {
    if [[ -e $STATE || -L $STATE ]]; then
        printf 'Хранилище уже зарегистрировано; проверяем существующие данные.\n'
        start_storage
        return
    fi
    local path image free_bytes
    [[ ! -e /dev/md0 && ! -e /sys/class/block/md0 ]] || fail '/dev/md0 уже занят.'
    if vgs "$VG" 9>&- >/dev/null 2>&1; then fail "Группа $VG уже существует без нашего файла состояния."; fi
    [[ ! -L $IMAGE_DIR ]] || fail "$IMAGE_DIR не должен быть ссылкой."
    mkdir -p "$IMAGE_DIR"
    check_directory "$IMAGE_DIR"
    for path in /mnt/raid /mnt/logs; do
        [[ ! -L $path ]] || fail "$path не должен быть ссылкой."
        mountpoint -q "$path" && fail "$path уже смонтирован."
        [[ ! -e $path || -d $path ]] || fail "$path не является каталогом."
        if [[ -d $path && -n $(find "$path" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
            fail "$path содержит файлы."
        fi
    done
    for image in disk1.img disk2.img disk3.img; do
        [[ ! -e $IMAGE_DIR/$image && ! -L $IMAGE_DIR/$image ]] ||
            fail "$IMAGE_DIR/$image уже существует. init никогда не перезаписывает диски."
    done
    free_bytes=$(df -B1 --output=avail "$IMAGE_DIR" | awk 'NR == 2 {print $1}')
    (( free_bytes >= 2147483648 )) || fail 'Для учебных дисков требуется не менее 2 ГиБ свободного места.'
    for image in disk1.img disk2.img disk3.img; do
        # noclobber запрещает открывать существующий файл даже при повторном запуске.
        (set -o noclobber; dd if=/dev/zero bs=1M count=512 status=none > "$IMAGE_DIR/$image")
    done
    attach_images
    mdadm --create /dev/md0 --metadata=1.2 --name=course-raid --level=1 --raid-devices=2 --run "$LOOP1" "$LOOP2"
    udevadm settle --timeout=30
    mkfs.ext4 -q /dev/md0
    pvcreate --yes "$LOOP3" 9>&-
    vgcreate "$VG" "$LOOP3" 9>&-
    lvcreate --yes -L 200M -n "$LV" "$VG" 9>&-
    udevadm settle --timeout=30
    mkfs.ext4 -q "$LV_DEVICE"
    RAID_UUID=$(md_uuid --detail /dev/md0)
    RAID_FS_UUID=$(blkid -s UUID -o value /dev/md0)
    PV_UUID=$(pvs --noheadings -o pv_uuid "$LOOP3" 9>&- | xargs)
    VG_UUID=$(vgs --noheadings -o vg_uuid "$VG" 9>&- | xargs)
    LV_UUID=$(lvs --noheadings -o lv_uuid "$VG/$LV" 9>&- | xargs)
    LOGS_FS_UUID=$(blkid -s UUID -o value "$LV_DEVICE")
    (set -o noclobber
        printf 'RAID_UUID=%s\nRAID_FS_UUID=%s\nPV_UUID=%s\nVG_UUID=%s\nLV_UUID=%s\nLOGS_FS_UUID=%s\n' \
            "$RAID_UUID" "$RAID_FS_UUID" "$PV_UUID" "$VG_UUID" "$LV_UUID" "$LOGS_FS_UUID" > "$STATE")
    start_storage
}

case $1 in
    init) init_storage ;;
    start) start_storage ;;
    status)
        load_state
        cat /proc/mdstat
        pvs 9>&-
        vgs 9>&-
        lvs -o lv_name,vg_name,lv_size,lv_attr,devices 9>&-
        findmnt --mountpoint /mnt/raid
        findmnt --mountpoint /mnt/logs
        df -h /mnt/raid /mnt/logs
        ;;
esac
