#!/bin/bash

# Full Server Setup — CentOS 7

# Запуск: bash server_setup.sh

LOG=”/var/log/server_setup.log”
touch “$LOG”
info()  { echo “[INFO]  $1” | tee -a “$LOG”; }
warn()  { echo “[WARN]  $1” | tee -a “$LOG”; }
error() { echo “[ERROR] $1” | tee -a “$LOG”; exit 1; }

[ “$(id -u)” -ne 0 ] && error “Запустите от root: bash $0”

# ── Пароли (смените перед запуском) ─────────────────────────────────────────

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

# ── TASK 1: HTTPD ────────────────────────────────────────────────────────────

info “=== TASK 1: HTTPD ===”
yum install -y httpd
systemctl enable httpd
systemctl start  httpd

# ── TASK 2: SAMBA ────────────────────────────────────────────────────────────

info “=== TASK 2: SAMBA ===”
yum install -y samba samba-client samba-common

id “$SAMBA_USER” >/dev/null 2>&1 || useradd -M -s /sbin/nologin “$SAMBA_USER”
printf “%s\n%s\n” “$SAMBA_PASS” “$SAMBA_PASS” | smbpasswd -a -s “$SAMBA_USER”
smbpasswd -e “$SAMBA_USER”

cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

# Пишем секцию samba через printf — без heredoc

{
printf ‘\n[webshare]\n’
printf ’   comment = Web HTML Share\n’
printf ’   path = /var/www/html\n’
printf ’   browseable = yes\n’
printf ’   read only = no\n’
printf ’   valid users = %s\n’ “$SAMBA_USER”
printf ’   create mask = 0664\n’
printf ’   directory mask = 0775\n’
} >> /etc/samba/smb.conf

systemctl enable smb nmb
systemctl restart smb nmb

# ── TASK 3: PHP ──────────────────────────────────────────────────────────────

info “=== TASK 3: PHP ===”
yum install -y php php-cli php-common
systemctl restart httpd

# ── TASK 4: OpenSSL ──────────────────────────────────────────────────────────

info “=== TASK 4: OpenSSL ===”
yum install -y openssl
echo “$ENC_PASS” > /etc/openssl_enc.pass
chmod 600 /etc/openssl_enc.pass

# encrypt_file.sh — пишем через printf построчно

{
printf ‘#!/bin/bash\n’
printf ‘SRC=”$1”; OUT_DIR=”${2:-/var/www/html/files}”\n’
printf ‘[ -z “$SRC” ] || [ ! -f “$SRC” ] && { echo “Использование: $0 <файл> [каталог]”; exit 1; }\n’
printf ‘PASS=$(cat /etc/openssl_enc.pass)\n’
printf ‘mkdir -p “$OUT_DIR”\n’
printf ‘NAME=$(basename “$SRC”)\n’
printf ‘openssl enc -aes-256-cbc -pbkdf2 -in “$SRC” -out “$OUT_DIR/${NAME}.enc” -pass “pass:$PASS”\n’
printf ‘echo “Зашифровано: $OUT_DIR/${NAME}.enc”\n’
} > /usr/local/bin/encrypt_file.sh

# decrypt_file.sh

{
printf ‘#!/bin/bash\n’
printf ‘SRC=”$1”; OUT_DIR=”${2:-.}”\n’
printf ‘[ -z “$SRC” ] || [ ! -f “$SRC” ] && { echo “Использование: $0 <файл.enc> [каталог]”; exit 1; }\n’
printf ‘PASS=$(cat /etc/openssl_enc.pass)\n’
printf ‘mkdir -p “$OUT_DIR”\n’
printf ‘NAME=$(basename “$SRC” .enc)\n’
printf ‘openssl enc -d -aes-256-cbc -pbkdf2 -in “$SRC” -out “$OUT_DIR/$NAME” -pass “pass:$PASS”\n’
printf ‘echo “Расшифровано: $OUT_DIR/$NAME”\n’
} > /usr/local/bin/decrypt_file.sh

chmod +x /usr/local/bin/encrypt_file.sh /usr/local/bin/decrypt_file.sh

# ── TASK 5: PHP сайт ─────────────────────────────────────────────────────────

info “=== TASK 5: PHP сайт ===”
mkdir -p “$FILES_DIR”
chown -R apache:apache “$FILES_DIR”
chmod 775 “$FILES_DIR”

PHP_FILE=”$WEB_ROOT/index.php”

# PHP часть — через printf, одинарные кавычки экранируем как ‘'’

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
'    $ok = ($rc === 0);' \
'    $cl = $ok ? "green" : "red";' \
'    $tx = $ok ? "Загружено: ".htmlspecialchars($name).".enc" : implode(" ",$res);' \
'    $message = "<p style=\"color:$cl\">$tx</p>";' \
'}' \
'?>’ > “$PHP_FILE”

# HTML часть — нет PHP тегов, heredoc безопасен

cat >> “$PHP_FILE” <<‘HTML_BLOCK’

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
.row{display:flex;gap:8px;align-items:center;margin-bottom:4px}
input[type=submit]{padding:4px 12px;cursor:pointer}
small{color:#999}
</style>
</head>
<body>
<h1>Файловый сервер</h1>
<h2>Загрузить файл</h2>
<form method="POST" enctype="multipart/form-data">
<div class="row">
<input type="file" name="upload" required>
<input type="submit" value="Загрузить и зашифровать">
</div>
</form>
HTML_BLOCK

# Остаток PHP — снова printf

printf ‘%s\n’   
‘<?php echo $message; ?>’   
‘<h2>Список файлов</h2>’   
‘<table>’   
‘<tr><th>Имя файла</th><th>Размер</th><th>Изменён</th><th>Скачать</th></tr>’   
‘<?php' \
'$files = glob($files_dir . "/*");' \
'if (empty($files)) { echo "<tr><td colspan=4>Файлов нет.</td></tr>"; }' \
'else {' \
'  foreach ($files as $f) {' \
'    $nm  = basename($f);' \
'    $sz  = round(filesize($f)/1024,2)." КБ";' \
'    $mt  = date("d.m.Y H:i", filemtime($f));' \
'    $url = "files/".rawurlencode($nm);' \
'    echo "<tr><td>".htmlspecialchars($nm)."</td><td>$sz</td><td>$mt</td><td><a href=\"$url\">скачать</a></td></tr>";' \
'  }' \
'}' \
'?>’   
‘</table>’   
‘<br><small>AES-256-CBC. Расшифровка: decrypt_file.sh файл.enc</small>’   
‘</body></html>’ >> “$PHP_FILE”

systemctl restart httpd

# ── TASK 6: /share ───────────────────────────────────────────────────────────

info “=== TASK 6: /share ===”
mkdir -p “$SHARE_DIR”
chmod 775 “$SHARE_DIR”

# ── TASK 7: rsync ────────────────────────────────────────────────────────────

info “=== TASK 7: rsync ===”
yum install -y rsync

{
printf ‘#!/bin/bash\n’
printf ‘SRC=”/var/www/html/files/”\n’
printf ‘DST=”/share/”\n’
printf ‘LOG=”/var/log/rsync_backup.log”\n’
printf ‘echo “$(date +%%Y-%%m-%%d\ %%H:%%M:%%S) start” >> “$LOG”\n’
printf ‘rsync -av –delete “$SRC” “$DST” >> “$LOG” 2>&1\n’
printf ‘echo “$(date +%%Y-%%m-%%d\ %%H:%%M:%%S) done”  >> “$LOG”\n’
} > /usr/local/bin/rsync_backup.sh
chmod +x /usr/local/bin/rsync_backup.sh

yum install -y epel-release 2>/dev/null || true
yum install -y inotify-tools 2>/dev/null || warn “inotify-tools недоступен”

if command -v inotifywait >/dev/null 2>&1; then
{
printf ‘#!/bin/bash\n’
printf ‘while true; do\n’
printf ’    inotifywait -r -e create,modify,delete,moved_to /var/www/html/files 2>/dev/null\n’
printf ’    /usr/local/bin/rsync_backup.sh\n’
printf ‘done\n’
} > /usr/local/bin/rsync_watch.sh
chmod +x /usr/local/bin/rsync_watch.sh

{
printf ‘[Unit]\nDescription=Rsync watcher\nAfter=network.target\n\n’
printf ‘[Service]\nExecStart=/usr/local/bin/rsync_watch.sh\nRestart=always\nRestartSec=5\n\n’
printf ‘[Install]\nWantedBy=multi-user.target\n’
} > /etc/systemd/system/rsync-watch.service

systemctl daemon-reload
systemctl enable rsync-watch
systemctl start  rsync-watch
info “inotify watcher запущен.”
fi

# ── TASK 8: Мониторинг ───────────────────────────────────────────────────────

info “=== TASK 8: Мониторинг ===”
yum install -y sysstat lm_sensors 2>/dev/null || true

{
printf ‘#!/bin/bash\n’
printf ‘LOG=”/var/log/server_monitor.log”\n’
printf ‘DT=$(date +”%%Y-%%m-%%d %%H:%%M:%%S”)\n’
printf ‘CPU=$(top -bn1 | grep “Cpu(s)” | awk ‘”’”’{print $2}’”’”’ | tr -d “%%us,”)\n’
printf ‘RAM_T=$(free -m | awk ‘”’”’/^Mem/{print $2}’”’”’)\n’
printf ‘RAM_U=$(free -m | awk ‘”’”’/^Mem/{print $3}’”’”’)\n’
printf ‘RAM_F=$(free -m | awk ‘”’”’/^Mem/{print $4}’”’”’)\n’
printf ‘DISK_U=$(df -h / | awk ‘”’”‘NR==2{print $3}’”’”’)\n’
printf ‘DISK_F=$(df -h / | awk ‘”’”‘NR==2{print $4}’”’”’)\n’
printf ‘DISK_P=$(df -h / | awk ‘”’”‘NR==2{print $5}’”’”’)\n’
printf ‘if command -v sensors >/dev/null 2>&1; then\n’
printf ’    CPU_T=$(sensors 2>/dev/null | awk ‘”’”’/Core 0|Package/{print $3; exit}’”’”’)\n’
printf ‘else\n’
printf ’    CPU_T=$(awk ‘”’”’{printf “%%.1f C”,$1/1000}’”’”’ /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo N/A)\n’
printf ‘fi\n’
printf ‘if command -v smartctl >/dev/null 2>&1; then\n’
printf ’    SSD_T=$(smartctl -A /dev/sda 2>/dev/null | awk ‘”’”’/Temperature_Celsius/{print $10” C”}’”’”’ || echo N/A)\n’
printf ‘else\n’
printf ’    SSD_T=“N/A”\n’
printf ‘fi\n’
printf ‘echo “[$DT] CPU:${CPU}%% RAM:${RAM_U}/${RAM_T}MB(free:${RAM_F}) Disk:${DISK_U}/${DISK_F}(${DISK_P}) CPU_T:${CPU_T} SSD_T:${SSD_T}” >> “$LOG”\n’
} > “$MONITOR_SCRIPT”
chmod +x “$MONITOR_SCRIPT”

# ── TASK 9: Очистка ──────────────────────────────────────────────────────────

info “=== TASK 9: Очистка ===”
{
printf ‘#!/bin/bash\n’
printf ‘DIR=”/var/www/html/files”\n’
printf ‘LOG=”/var/log/cleanup_files.log”\n’
printf ‘DT=$(date +”%%Y-%%m-%%d %%H:%%M:%%S”)\n’
printf ‘COUNT=0\n’
printf ‘for f in “$DIR”/*; do\n’
printf ’    [ -f “$f” ] || continue\n’
printf ’    rm -f “$f”\n’
printf ’    echo “[$DT] Удалён: $(basename “$f”)” >> “$LOG”\n’
printf ’    COUNT=$((COUNT+1))\n’
printf ‘done\n’
printf ‘echo “[$DT] Готово. Удалено: $COUNT” >> “$LOG”\n’
} > “$CLEANUP_SCRIPT”
chmod +x “$CLEANUP_SCRIPT”

# ── CRON (tasks 7,8,9) ───────────────────────────────────────────────────────

info “=== CRON ===”
crontab -l 2>/dev/null   
| grep -v rsync_backup   
| grep -v server_monitor   
| grep -v cleanup_files > /tmp/_cron_tmp || true
printf ‘*/5  * * * * /usr/local/bin/rsync_backup.sh\n’  >> /tmp/_cron_tmp
printf ’*/5  * * * * %s\n’ “$MONITOR_SCRIPT”             >> /tmp/_cron_tmp
printf ‘*/10 * * * * %s\n’ “$CLEANUP_SCRIPT”             >> /tmp/_cron_tmp
crontab /tmp/_cron_tmp
rm -f /tmp/_cron_tmp

# ── TASK 10: HTTP Basic Auth ─────────────────────────────────────────────────

info “=== TASK 10: HTTP Basic Auth ===”
yum install -y httpd-tools
HTPASSWD_FILE=”/etc/httpd/.htpasswd”
htpasswd -bc “$HTPASSWD_FILE” “$HTPASSWD_USER” “$HTPASSWD_PASS”
chmod 640 “$HTPASSWD_FILE”

{
printf ‘<Directory /var/www/html/files>\n’
printf ’    AuthType Basic\n’
printf ’    AuthName “Restricted”\n’
printf ’    AuthUserFile /etc/httpd/.htpasswd\n’
printf ’    Require valid-user\n’
printf ’    Options +Indexes\n’
printf ‘</Directory>\n’
} > /etc/httpd/conf.d/files-auth.conf

systemctl restart httpd

# ── Firewall ─────────────────────────────────────────────────────────────────

info “=== Firewall ===”
if command -v firewall-cmd >/dev/null 2>&1; then
firewall-cmd –permanent –add-service=http   2>/dev/null || true
firewall-cmd –permanent –add-service=https  2>/dev/null || true
firewall-cmd –permanent –add-service=samba  2>/dev/null || true
firewall-cmd –reload 2>/dev/null || true
fi

# ── SELinux ───────────────────────────────────────────────────────────────────

info “=== SELinux ===”
if command -v setsebool >/dev/null 2>&1; then
setsebool -P httpd_unified 1          2>/dev/null || true
chcon -Rt httpd_sys_rw_content_t “$FILES_DIR” 2>/dev/null || true
fi

# ── Итог ─────────────────────────────────────────────────────────────────────

echo “”
echo “=================================================================”
echo “  ГОТОВО”
echo “=================================================================”
echo “  [1]  Apache   : http://<ip>/”
echo “  [2]  SAMBA    : \\<ip>\webshare  логин: $SAMBA_USER / $SAMBA_PASS”
echo “  [3]  PHP      : установлен”
echo “  [4]  OpenSSL  : encrypt_file.sh / decrypt_file.sh”
echo “  [5]  Сайт     : http://<ip>/”
echo “  [6]  /share   : готов”
echo “  [7]  rsync    : каждые 5 мин + inotify”
echo “  [8]  Монитор  : /var/log/server_monitor.log (каждые 5 мин)”
echo “  [9]  Очистка  : /var/log/cleanup_files.log  (каждые 10 мин)”
echo “  [10] BasicAuth: /files  логин: $HTPASSWD_USER / $HTPASSWD_PASS”
echo “=================================================================”
