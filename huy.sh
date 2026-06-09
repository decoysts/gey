#!/bin/bash

# =============================================================================

# Full Server Setup Script — CentOS 7

# Tasks: HTTPD, SAMBA, PHP, OpenSSL, File site, rsync,

# CRON, monitoring, cleanup, HTTP Basic Auth

# Запуск: bash server_setup.sh

# =============================================================================

LOG=”/var/log/server_setup.log”
touch “$LOG”

info()  { echo “[INFO]  $1” | tee -a “$LOG”; }
warn()  { echo “[WARN]  $1” | tee -a “$LOG”; }
error() { echo “[ERROR] $1” | tee -a “$LOG”; exit 1; }

if [ “$(id -u)” -ne 0 ]; then
error “Запустите скрипт от root: bash $0”
fi

# =============================================================================

# Переменные — СМЕНИТЕ ПАРОЛИ перед запуском

# =============================================================================

WEB_ROOT=”/var/www/html”
FILES_DIR=”$WEB_ROOT/files”
SHARE_DIR=”/share”
SAMBA_USER=“sambauser”
SAMBA_PASS=“SambaPass123”
ENC_PASS=“EncryptPass456”
HTPASSWD_USER=“admin”
HTPASSWD_PASS=“AdminPass789”
MONITOR_SCRIPT=”/usr/local/bin/server_monitor.sh”
CLEANUP_SCRIPT=”/usr/local/bin/cleanup_files.sh”

# =============================================================================

# TASK 1 — HTTPD (Apache)

# =============================================================================

info “=== TASK 1: Установка HTTPD ===”
yum install -y httpd
systemctl enable httpd
systemctl start httpd
info “Apache запущен.”

# =============================================================================

# TASK 2 — SAMBA

# =============================================================================

info “=== TASK 2: Установка и настройка SAMBA ===”
yum install -y samba samba-client samba-common

id “$SAMBA_USER” >/dev/null 2>&1 || useradd -M -s /sbin/nologin “$SAMBA_USER”
printf “%s\n%s\n” “$SAMBA_PASS” “$SAMBA_PASS” | smbpasswd -a -s “$SAMBA_USER”
smbpasswd -e “$SAMBA_USER”

cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

cat >> /etc/samba/smb.conf << ‘SMBEOF’

[webshare]
comment = Web HTML Share
path = /var/www/html
browseable = yes
read only = no
valid users = sambauser
create mask = 0664
directory mask = 0775
SMBEOF

systemctl enable smb nmb
systemctl restart smb nmb
info “SAMBA настроена. Шара: \\<ip>\webshare  Пользователь: $SAMBA_USER”

# =============================================================================

# TASK 3 — PHP

# =============================================================================

info “=== TASK 3: Установка PHP ===”
yum install -y php php-cli php-common
systemctl restart httpd
php -v
info “PHP установлен.”

# =============================================================================

# TASK 4 — OpenSSL + скрипты шифрования

# =============================================================================

info “=== TASK 4: Настройка OpenSSL ===”
yum install -y openssl

cat > /usr/local/bin/encrypt_file.sh << ‘ENCEOF’
#!/bin/bash

# Использование: encrypt_file.sh <файл> [каталог_назначения]

SRC=”$1”
OUT_DIR=”${2:-/var/www/html/files}”
if [ -z “$SRC” ] || [ ! -f “$SRC” ]; then
echo “Использование: $0 <файл> [каталог]”
exit 1
fi
PASS=$(cat /etc/openssl_enc.pass)
mkdir -p “$OUT_DIR”
NAME=$(basename “$SRC”)
openssl enc -aes-256-cbc -pbkdf2 -in “$SRC” -out “$OUT_DIR/${NAME}.enc” -pass “pass:$PASS”
echo “Зашифровано: $OUT_DIR/${NAME}.enc”
ENCEOF

cat > /usr/local/bin/decrypt_file.sh << ‘DECEOF’
#!/bin/bash

# Использование: decrypt_file.sh <файл.enc> [каталог_назначения]

SRC=”$1”
OUT_DIR=”${2:-.}”
if [ -z “$SRC” ] || [ ! -f “$SRC” ]; then
echo “Использование: $0 <файл.enc> [каталог]”
exit 1
fi
PASS=$(cat /etc/openssl_enc.pass)
mkdir -p “$OUT_DIR”
NAME=$(basename “$SRC” .enc)
openssl enc -d -aes-256-cbc -pbkdf2 -in “$SRC” -out “$OUT_DIR/$NAME” -pass “pass:$PASS”
echo “Расшифровано: $OUT_DIR/$NAME”
DECEOF

echo “$ENC_PASS” > /etc/openssl_enc.pass
chmod 600 /etc/openssl_enc.pass
chmod +x /usr/local/bin/encrypt_file.sh /usr/local/bin/decrypt_file.sh
info “OpenSSL: encrypt_file.sh / decrypt_file.sh готовы.”

# =============================================================================

# TASK 5 — PHP сайт (список файлов + загрузка с шифрованием)

# =============================================================================

info “=== TASK 5: Создание PHP сайта ===”
mkdir -p “$FILES_DIR”
chown -R apache:apache “$FILES_DIR”
chmod 775 “$FILES_DIR”

PHP_FILE=”$WEB_ROOT/index.php”

# Пишем PHP через printf — избегаем конфликта ?> с bash

printf ‘%s\n’   
‘<?php' \
'$files_dir = __DIR__ . "/files";' \
'$message = "";' \
'if ($_SERVER["REQUEST_METHOD"] === "POST" && isset($_FILES["upload"])) {' \
'    $pass = trim(file_get_contents("/etc/openssl_enc.pass"));' \
'    $tmp  = $_FILES["upload"]["tmp_name"];' \
'    $name = basename($_FILES["upload"]["name"]);' \
'    $out  = $files_dir . "/" . $name . ".enc";' \
'    $cmd  = "openssl enc -aes-256-cbc -pbkdf2 -in " . escapeshellarg($tmp)' \
'          . " -out " . escapeshellarg($out)' \
'          . " -pass pass:" . escapeshellarg($pass) . " 2>&1";' \
'    exec($cmd, $res, $rc);' \
'    if ($rc === 0) {' \
'        $message = "<p style=\"color:green\">Загружено и зашифровано: " . htmlspecialchars($name) . ".enc</p>";' \
'    } else {' \
'        $message = "<p style=\"color:red\">Ошибка: " . implode(" ", $res) . "</p>";' \
'    }' \
'}' \
'?>’ > “$PHP_FILE”

cat >> “$PHP_FILE” << ‘HTMLEOF’

<!DOCTYPE html>

<html lang="ru">
<head>
<meta charset="UTF-8">
<title>Файловый сервер</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:monospace;font-size:14px;background:#fff;color:#111;padding:30px;max-width:860px}
  h1{font-size:16px;margin-bottom:20px;border-bottom:1px solid #bbb;padding-bottom:8px}
  h2{font-size:13px;margin:20px 0 6px;text-transform:uppercase;color:#555}
  table{width:100%;border-collapse:collapse}
  th,td{padding:5px 8px;border:1px solid #ccc;text-align:left}
  th{background:#f0f0f0}
  a{color:#00e}
  .upload{display:flex;gap:8px;align-items:center;margin-bottom:4px}
  input[type=submit]{padding:4px 12px;cursor:pointer}
  small{color:#999}
</style>
</head>
<body>
<h1>Файловый сервер — зашифрованные файлы</h1>
<h2>Загрузить файл</h2>
<form method="POST" enctype="multipart/form-data">
  <div class="upload">
    <input type="file" name="upload" required>
    <input type="submit" value="Загрузить и зашифровать">
  </div>
</form>
HTMLEOF

printf ‘%s\n’   
‘<?php echo $message; ?>’   
‘<h2>Список файлов</h2>’   
‘<table>’   
‘<tr><th>Имя файла</th><th>Размер</th><th>Изменён</th><th>Скачать</th></tr>’   
‘<?php' \
'$files = glob($files_dir . "/*");' \
'if (empty($files)) {' \
'    echo "<tr><td colspan=4>Файлов нет.</td></tr>";' \
'} else {' \
'    foreach ($files as $f) {' \
'        $nm   = basename($f);' \
'        $size = round(filesize($f)/1024, 2) . " КБ";' \
'        $mt   = date("d.m.Y H:i", filemtime($f));' \
'        $url  = "files/" . rawurlencode($nm);' \
'        echo "<tr><td>" . htmlspecialchars($nm) . "</td><td>$size</td><td>$mt</td>"' \
'           . "<td><a href=\"$url\">скачать</a></td></tr>";' \
'    }' \
'}' \
'?>’   
‘</table>’   
‘<br><small>AES-256-CBC. Расшифровка: decrypt_file.sh <файл.enc></small>’   
‘</body></html>’ >> “$PHP_FILE”

systemctl restart httpd
info “PHP сайт создан: http://<ip>/”

# =============================================================================

# TASK 6 — Каталог /share

# =============================================================================

info “=== TASK 6: Создание /share ===”
mkdir -p “$SHARE_DIR”
chmod 775 “$SHARE_DIR”
info “/share готов.”

# =============================================================================

# TASK 7 — rsync: синхронизация files -> /share при добавлении файлов

# =============================================================================

info “=== TASK 7: Настройка rsync ===”
yum install -y rsync

cat > /usr/local/bin/rsync_backup.sh << ‘RSYNCEOF’
#!/bin/bash
SRC=”/var/www/html/files/”
DST=”/share/”
LOG=”/var/log/rsync_backup.log”
echo “$(date ‘+%Y-%m-%d %H:%M:%S’) rsync start” >> “$LOG”
rsync -av –delete “$SRC” “$DST” >> “$LOG” 2>&1
echo “$(date ‘+%Y-%m-%d %H:%M:%S’) rsync done”  >> “$LOG”
RSYNCEOF
chmod +x /usr/local/bin/rsync_backup.sh

# inotifywait — если есть epel

yum install -y epel-release 2>/dev/null || true
yum install -y inotify-tools 2>/dev/null || warn “inotify-tools недоступен, только cron”

if command -v inotifywait >/dev/null 2>&1; then
cat > /usr/local/bin/rsync_watch.sh << ‘WATCHEOF’
#!/bin/bash
while true; do
inotifywait -r -e create,modify,delete,moved_to /var/www/html/files 2>/dev/null
/usr/local/bin/rsync_backup.sh
done
WATCHEOF
chmod +x /usr/local/bin/rsync_watch.sh

```
cat > /etc/systemd/system/rsync-watch.service << 'SVCEOF'
```

[Unit]
Description=Rsync watcher /var/www/html/files
After=network.target

[Service]
ExecStart=/usr/local/bin/rsync_watch.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable rsync-watch
systemctl start  rsync-watch
info “inotify watcher запущен (rsync-watch.service)”
fi

# =============================================================================

# TASK 8 — Мониторинг сервера (TEMP, CPU, SSD, RAM) -> лог

# =============================================================================

info “=== TASK 8: Скрипт мониторинга ===”
yum install -y sysstat lm_sensors 2>/dev/null || true

cat > “$MONITOR_SCRIPT” << ‘MONEOF’
#!/bin/bash
LOG=”/var/log/server_monitor.log”
DT=$(date ‘+%Y-%m-%d %H:%M:%S’)

CPU=$(top -bn1 | grep “Cpu(s)” | awk ‘{print $2}’ | tr -d ‘%us,’)
RAM_T=$(free -m | awk ‘/^Mem/{print $2}’)
RAM_U=$(free -m | awk ‘/^Mem/{print $3}’)
RAM_F=$(free -m | awk ‘/^Mem/{print $4}’)
DISK_U=$(df -h / | awk ‘NR==2{print $3}’)
DISK_F=$(df -h / | awk ‘NR==2{print $4}’)
DISK_P=$(df -h / | awk ‘NR==2{print $5}’)

if command -v sensors >/dev/null 2>&1; then
CPU_T=$(sensors 2>/dev/null | awk ‘/Core 0|Package/{print $3; exit}’)
else
CPU_T=$(awk ‘{printf “%.1f C”, $1/1000}’ /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo “N/A”)
fi

if command -v smartctl >/dev/null 2>&1; then
SSD_T=$(smartctl -A /dev/sda 2>/dev/null | awk ‘/Temperature_Celsius/{print $10” C”}’ || echo “N/A”)
else
SSD_T=“N/A”
fi

echo “[$DT] CPU: ${CPU}% | RAM: ${RAM_U}/${RAM_T} MB (своб: ${RAM_F} MB) | Диск: ${DISK_U} исп, ${DISK_F} своб (${DISK_P}) | CPU темп: ${CPU_T} | SSD темп: ${SSD_T}” >> “$LOG”
MONEOF
chmod +x “$MONITOR_SCRIPT”
info “Скрипт мониторинга: $MONITOR_SCRIPT  Лог: /var/log/server_monitor.log”

# =============================================================================

# TASK 9 — Скрипт очистки /var/www/html/files каждые 10 мин (cron)

# =============================================================================

info “=== TASK 9: Скрипт очистки файлов ===”
cat > “$CLEANUP_SCRIPT” << ‘CLEANEOF’
#!/bin/bash
DIR=”/var/www/html/files”
LOG=”/var/log/cleanup_files.log”
DT=$(date ‘+%Y-%m-%d %H:%M:%S’)
COUNT=0
for f in “$DIR”/*; do
[ -f “$f” ] || continue
rm -f “$f”
echo “[$DT] Удалён: $(basename “$f”)” >> “$LOG”
COUNT=$((COUNT+1))
done
echo “[$DT] Очистка завершена. Удалено: $COUNT” >> “$LOG”
CLEANEOF
chmod +x “$CLEANUP_SCRIPT”
info “Скрипт очистки: $CLEANUP_SCRIPT  Лог: /var/log/cleanup_files.log”

# =============================================================================

# Cron задачи (Tasks 7, 8, 9)

# =============================================================================

info “=== Добавление заданий CRON ===”
crontab -l 2>/dev/null | grep -v rsync_backup | grep -v server_monitor | grep -v cleanup_files > /tmp/crontab_tmp || true
echo “*/5  * * * * /usr/local/bin/rsync_backup.sh”  >> /tmp/crontab_tmp
echo “*/5  * * * * $MONITOR_SCRIPT”                  >> /tmp/crontab_tmp
echo “*/10 * * * * $CLEANUP_SCRIPT”                  >> /tmp/crontab_tmp
crontab /tmp/crontab_tmp
rm -f /tmp/crontab_tmp
info “Cron: rsync каждые 5 мин, мониторинг каждые 5 мин, очистка каждые 10 мин.”

# =============================================================================

# TASK 10 — HTTP Basic Auth на /var/www/html/files

# =============================================================================

info “=== TASK 10: HTTP Basic Auth ===”
yum install -y httpd-tools

HTPASSWD_FILE=”/etc/httpd/.htpasswd”
htpasswd -bc “$HTPASSWD_FILE” “$HTPASSWD_USER” “$HTPASSWD_PASS”
chmod 640 “$HTPASSWD_FILE”

cat > /etc/httpd/conf.d/files-auth.conf << AUTHEOF
<Directory /var/www/html/files>
AuthType Basic
AuthName “Restricted Files”
AuthUserFile /etc/httpd/.htpasswd
Require valid-user
Options +Indexes
</Directory>
AUTHEOF

systemctl restart httpd
info “HTTP Basic Auth включён на /files.  Логин: $HTPASSWD_USER  Пароль: $HTPASSWD_PASS”

# =============================================================================

# Firewall

# =============================================================================

info “=== Настройка firewall ===”
if command -v firewall-cmd >/dev/null 2>&1; then
firewall-cmd –permanent –add-service=http
firewall-cmd –permanent –add-service=https
firewall-cmd –permanent –add-service=samba
firewall-cmd –reload
info “firewalld: открыты HTTP, HTTPS, Samba.”
else
warn “firewalld не найден — откройте порты 80, 443, 137-139, 445 вручную.”
fi

# =============================================================================

# SELinux — разрешить Apache писать в /files

# =============================================================================

info “=== SELinux ===”
if command -v setsebool >/dev/null 2>&1; then
setsebool -P httpd_unified 1 2>/dev/null || true
setsebool -P httpd_execmem 1 2>/dev/null || true
chcon -Rt httpd_sys_rw_content_t “$FILES_DIR” 2>/dev/null || true
info “SELinux: права для Apache на /files установлены.”
fi

# =============================================================================

# Итог

# =============================================================================

echo “”
echo “=================================================================”
echo “  УСТАНОВКА ЗАВЕРШЕНА”
echo “=================================================================”
echo “  [1]  Apache        : запущен  — http://<ip>/”
echo “  [2]  SAMBA         : запущен  — \\<ip>\webshare”
echo “       Логин/пароль  : $SAMBA_USER / $SAMBA_PASS”
echo “  [3]  PHP           : установлен”
echo “  [4]  OpenSSL       : encrypt_file.sh / decrypt_file.sh”
echo “       Ключ шифровки : /etc/openssl_enc.pass”
echo “  [5]  PHP сайт      : http://<ip>/”
echo “  [6]  /share        : готов”
echo “  [7]  rsync         : каждые 5 мин + inotify (если установлен)”
echo “  [8]  Мониторинг    : $MONITOR_SCRIPT”
echo “       Лог           : /var/log/server_monitor.log”
echo “  [9]  Очистка       : $CLEANUP_SCRIPT (каждые 10 мин)”
echo “       Лог           : /var/log/cleanup_files.log”
echo “  [10] Basic Auth    : /files — $HTPASSWD_USER / $HTPASSWD_PASS”
echo “=================================================================”
echo “  ВНИМАНИЕ: Смените пароли в начале скрипта перед использованием!”
echo “=================================================================”
