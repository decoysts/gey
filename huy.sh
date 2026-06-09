#!/bin/bash

# =============================================================================

# Full Server Setup Script

# Tasks: HTTPD, SAMBA, PHP, OpenSSL, File site, rsync backup,

# CRON rsync, monitoring script, cleanup script, HTTP Basic Auth

# Run as: sudo bash server_setup.sh

# =============================================================================

set -e
LOG=”/var/log/server_setup.log”
exec > >(tee -a “$LOG”) 2>&1

RED=’\033[0;31m’; GREEN=’\033[0;32m’; YELLOW=’\033[1;33m’; NC=’\033[0m’
info()    { echo -e “${GREEN}[INFO]${NC} $1”; }
warn()    { echo -e “${YELLOW}[WARN]${NC} $1”; }
error()   { echo -e “${RED}[ERROR]${NC} $1”; exit 1; }

[[ $EUID -ne 0 ]] && error “Run this script as root: sudo bash $0”

# ── Detect distro ────────────────────────────────────────────────────────────

if command -v apt-get &>/dev/null; then
PKG_INSTALL=“apt-get install -y”
PKG_UPDATE=“apt-get update -y”
HTTPD_SERVICE=“apache2”
HTTPD_PKG=“apache2”
SAMBA_PKG=“samba”
PHP_PKG=“php libapache2-mod-php php-cli”
OPENSSL_PKG=“openssl”
LMSENSORS_PKG=“lm-sensors”
SYSSTAT_PKG=“sysstat”
elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
PKG_MGR=$(command -v dnf || echo yum)
PKG_INSTALL=”$PKG_MGR install -y”
PKG_UPDATE=”$PKG_MGR makecache”
HTTPD_SERVICE=“httpd”
HTTPD_PKG=“httpd”
SAMBA_PKG=“samba samba-client”
PHP_PKG=“php”
OPENSSL_PKG=“openssl”
LMSENSORS_PKG=“lm_sensors”
SYSSTAT_PKG=“sysstat”
else
error “Unsupported distro. Use Debian/Ubuntu or RHEL/CentOS/Rocky.”
fi

# ── Directories & variables ───────────────────────────────────────────────────

WEB_ROOT=”/var/www/html”
FILES_DIR=”$WEB_ROOT/files”
SHARE_DIR=”/share”
SAMBA_USER=“sambauser”
SAMBA_PASS=“SambaPass123!”          # Change this
ENC_PASS=“EncryptPass456!”          # Change this — used for OpenSSL encryption
HTPASSWD_USER=“admin”
HTPASSWD_PASS=“AdminPass789!”       # Change this
MONITOR_SCRIPT=”/usr/local/bin/server_monitor.sh”
CLEANUP_SCRIPT=”/usr/local/bin/cleanup_files.sh”

# =============================================================================

# TASK 1 — Install & start HTTPD (Apache)

# =============================================================================

info “=== TASK 1: Installing HTTPD (Apache) ===”
$PKG_UPDATE
$PKG_INSTALL $HTTPD_PKG

systemctl enable $HTTPD_SERVICE
systemctl start  $HTTPD_SERVICE
info “Apache is running.”

# =============================================================================

# TASK 2 — Install & configure SAMBA (share /var/www/html/)

# =============================================================================

info “=== TASK 2: Installing and configuring SAMBA ===”
$PKG_INSTALL $SAMBA_PKG rsync

# Create samba user

id “$SAMBA_USER” &>/dev/null || useradd -M -s /sbin/nologin “$SAMBA_USER”
echo -e “$SAMBA_PASS\n$SAMBA_PASS” | smbpasswd -a -s “$SAMBA_USER”
smbpasswd -e “$SAMBA_USER”

# Backup original smb.conf

cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

cat >> /etc/samba/smb.conf <<SMBEOF

[webshare]
comment = Web HTML Share
path = $WEB_ROOT
browseable = yes
read only = no
valid users = $SAMBA_USER
create mask = 0664
directory mask = 0775
SMBEOF

systemctl enable smb nmb 2>/dev/null || systemctl enable smbd nmbd 2>/dev/null || true
systemctl restart smb nmb  2>/dev/null || systemctl restart smbd nmbd 2>/dev/null || true
info “SAMBA configured. Share: \\<server-ip>\webshare  User: $SAMBA_USER”

# =============================================================================

# TASK 3 — Install PHP

# =============================================================================

info “=== TASK 3: Installing PHP ===”
$PKG_INSTALL $PHP_PKG
systemctl restart $HTTPD_SERVICE
php -v
info “PHP installed.”

# =============================================================================

# TASK 4 — Install OpenSSL + helper scripts for encrypting/decrypting files

# =============================================================================

info “=== TASK 4: Setting up OpenSSL encryption helpers ===”
$PKG_INSTALL $OPENSSL_PKG

# Encrypt helper

cat > /usr/local/bin/encrypt_file.sh <<‘ENCEOF’
#!/bin/bash

# Usage: encrypt_file.sh <source_file> [output_dir]

SRC=”$1”
OUT_DIR=”${2:-/var/www/html/files}”
[[ -z “$SRC” ]] && { echo “Usage: $0 <file> [output_dir]”; exit 1; }
[[ ! -f “$SRC” ]] && { echo “File not found: $SRC”; exit 1; }
PASS_FILE=”/etc/openssl_enc.pass”
[[ ! -f “$PASS_FILE” ]] && { echo “Password file $PASS_FILE not found!”; exit 1; }
mkdir -p “$OUT_DIR”
BASENAME=$(basename “$SRC”)
openssl enc -aes-256-cbc -pbkdf2 -in “$SRC” -out “$OUT_DIR/${BASENAME}.enc” -pass “file:$PASS_FILE”
echo “Encrypted: $OUT_DIR/${BASENAME}.enc”
ENCEOF

# Decrypt helper

cat > /usr/local/bin/decrypt_file.sh <<‘DECEOF’
#!/bin/bash

# Usage: decrypt_file.sh <encrypted_file> [output_dir]

SRC=”$1”
OUT_DIR=”${2:-.}”
[[ -z “$SRC” ]] && { echo “Usage: $0 <encrypted_file> [output_dir]”; exit 1; }
[[ ! -f “$SRC” ]] && { echo “File not found: $SRC”; exit 1; }
PASS_FILE=”/etc/openssl_enc.pass”
[[ ! -f “$PASS_FILE” ]] && { echo “Password file $PASS_FILE not found!”; exit 1; }
mkdir -p “$OUT_DIR”
BASENAME=$(basename “$SRC” .enc)
openssl enc -d -aes-256-cbc -pbkdf2 -in “$SRC” -out “$OUT_DIR/${BASENAME}” -pass “file:$PASS_FILE”
echo “Decrypted: $OUT_DIR/$BASENAME”
DECEOF

# Store encryption password securely

echo “$ENC_PASS” > /etc/openssl_enc.pass
chmod 600 /etc/openssl_enc.pass
chmod +x /usr/local/bin/encrypt_file.sh /usr/local/bin/decrypt_file.sh
info “OpenSSL helpers: encrypt_file.sh / decrypt_file.sh”

# =============================================================================

# TASK 5 — PHP site that lists /var/www/html/files + upload encrypted files

# =============================================================================

info “=== TASK 5: Creating file-listing PHP site ===”
mkdir -p “$FILES_DIR”
chown -R apache:apache “$FILES_DIR” 2>/dev/null || chown -R www-data:www-data “$FILES_DIR” 2>/dev/null || true
chmod 775 “$FILES_DIR”

python3 - “$WEB_ROOT/index.php” <<‘PYEOF’
import sys
php = r”””<?php
$files_dir = **DIR** . ‘/files’;
$message   = ‘’;

if ($_SERVER[‘REQUEST_METHOD’] === ‘POST’ && isset($_FILES[‘upload’])) {
$pass_file = ‘/etc/openssl_enc.pass’;
$pass      = trim(file_get_contents($pass_file));
$tmp       = $_FILES[‘upload’][‘tmp_name’];
$name      = basename($_FILES[‘upload’][‘name’]);
$enc_path  = $files_dir . ‘/’ . $name . ‘.enc’;
$cmd = “openssl enc -aes-256-cbc -pbkdf2 -in “ . escapeshellarg($tmp)
. “ -out “ . escapeshellarg($enc_path)
. “ -pass pass:” . escapeshellarg($pass) . “ 2>&1”;
exec($cmd, $out, $rc);
$message = $rc === 0
? “<p class='ok'>Файл загружен и зашифрован: {$name}.enc</p>”
: “<p class='err'>Ошибка: “ . implode(’ ’, $out) . “</p>”;
}
?>

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
  .ok{color:green;margin:6px 0}
  .err{color:red;margin:6px 0}
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
<?php echo $message; ?>

<h2>Список файлов</h2>
<table>
  <tr><th>Имя файла</th><th>Размер</th><th>Изменён</th><th>Действие</th></tr>
  <?php
  $files = glob($files_dir . '/*');
  if (empty($files)) {
      echo "<tr><td colspan='4'>Файлов нет.</td></tr>";
  } else {
      foreach ($files as $f) {
          $name  = basename($f);
          $size  = round(filesize($f)/1024, 2) . ' КБ';
          $mtime = date('d.m.Y H:i:s', filemtime($f));
          $url   = 'files/' . rawurlencode($name);
          echo "<tr><td>$name</td><td>$size</td><td>$mtime</td><td><a href='$url'>скачать</a></td></tr>";
      }
  }
  ?>
</table>
<br><small>Файлы зашифрованы (AES-256-CBC). Для расшифровки: <code>decrypt_file.sh &lt;файл.enc&gt;</code></small>
</body></html>
"""
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    f.write(php)
PYEOF

systemctl restart $HTTPD_SERVICE
info “PHP site created at http://<server-ip>/”

# =============================================================================

# TASK 6 — Create /share directory (rsync backup destination)

# =============================================================================

info “=== TASK 6: Creating /share backup directory ===”
mkdir -p “$SHARE_DIR”
chmod 775 “$SHARE_DIR”
info “/share directory ready.”

# =============================================================================

# TASK 7 — RSYNC sync /var/www/html/files → /share via CRON (task 7 sets it up,

# cron entries added in task 7 & 8 block below)

# =============================================================================

info “=== TASK 7: Setting up RSYNC sync script ===”

cat > /usr/local/bin/rsync_backup.sh <<‘RSYNCEOF’
#!/bin/bash

# Syncs /var/www/html/files → /share

SRC=”/var/www/html/files/”
DST=”/share/”
LOG=”/var/log/rsync_backup.log”
echo “$(date ‘+%Y-%m-%d %H:%M:%S’) Starting rsync…” >> “$LOG”
rsync -av –delete “$SRC” “$DST” >> “$LOG” 2>&1
echo “$(date ‘+%Y-%m-%d %H:%M:%S’) Done.” >> “$LOG”
RSYNCEOF
chmod +x /usr/local/bin/rsync_backup.sh

# inotifywait-based watcher (runs on file addition) — optional daemon

$PKG_INSTALL inotify-tools 2>/dev/null || warn “inotify-tools not available, relying on cron only”

if command -v inotifywait &>/dev/null; then
cat > /usr/local/bin/rsync_watch.sh <<‘WATCHEOF’
#!/bin/bash

# Watches /var/www/html/files and triggers rsync on any change

SRC=”/var/www/html/files”
while true; do
inotifywait -r -e create,modify,delete,moved_to “$SRC” 2>/dev/null
/usr/local/bin/rsync_backup.sh
done
WATCHEOF
chmod +x /usr/local/bin/rsync_watch.sh

# Create systemd service for the watcher

cat > /etc/systemd/system/rsync-watch.service <<‘SVCEOF’
[Unit]
Description=Rsync watcher for /var/www/html/files
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
info “inotify watcher running as rsync-watch.service”
fi

# =============================================================================

# TASK 8 — BASH monitoring script (TEMP, CPU, SSD, RAM) → log with timestamp

# =============================================================================

info “=== TASK 8: Creating server monitoring script ===”
$PKG_INSTALL $SYSSTAT_PKG $LMSENSORS_PKG 2>/dev/null || true

cat > “$MONITOR_SCRIPT” <<‘MONEOF’
#!/bin/bash

# Server monitoring: TEMP, CPU, SSD, RAM — appends to log with timestamp

LOG=”/var/log/server_monitor.log”
DATE=$(date ‘+%Y-%m-%d %H:%M:%S’)

# CPU usage (idle %)

CPU_IDLE=$(top -bn1 | grep “Cpu(s)” | awk ‘{print $8}’ | tr -d ‘%’)
CPU_USED=$(echo “100 - $CPU_IDLE” | bc 2>/dev/null || echo “N/A”)

# RAM

RAM_TOTAL=$(free -m | awk ‘/^Mem:/{print $2}’)
RAM_USED=$(free  -m | awk ‘/^Mem:/{print $3}’)
RAM_FREE=$(free  -m | awk ‘/^Mem:/{print $4}’)

# Disk (root)

DISK_USED=$(df -h / | awk ‘NR==2{print $3}’)
DISK_FREE=$(df -h / | awk ‘NR==2{print $4}’)
DISK_PCT=$(df -h  / | awk ‘NR==2{print $5}’)

# CPU Temperature

if command -v sensors &>/dev/null; then
CPU_TEMP=$(sensors 2>/dev/null | grep -i ‘core 0|Package id 0|temp1’ | head -1 | awk ‘{print $3}’ || echo “N/A”)
else
CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null   
| awk ‘{printf “%.1f°C”, $1/1000}’ || echo “N/A”)
fi

# SSD/HDD temp via smartctl

if command -v smartctl &>/dev/null; then
SSD_TEMP=$(smartctl -A /dev/sda 2>/dev/null | awk ‘/Temperature_Celsius/{print $10”°C”}’ || echo “N/A”)
else
SSD_TEMP=“N/A (install smartmontools)”
fi

LOG_LINE=”[$DATE] CPU: ${CPU_USED}% | RAM: ${RAM_USED}MB/${RAM_TOTAL}MB (free: ${RAM_FREE}MB) | Disk: ${DISK_USED} used, ${DISK_FREE} free (${DISK_PCT}) | CPU Temp: ${CPU_TEMP} | SSD Temp: ${SSD_TEMP}”
echo “$LOG_LINE” >> “$LOG”
echo “$LOG_LINE”
MONEOF
chmod +x “$MONITOR_SCRIPT”
info “Monitor script: $MONITOR_SCRIPT”

# =============================================================================

# TASK 9 — Cleanup script: delete files in /var/www/html/files every 10 min,

# but preserve /share (backup), launched via CRON

# =============================================================================

info “=== TASK 9: Creating cleanup script ===”

cat > “$CLEANUP_SCRIPT” <<‘CLEANEOF’
#!/bin/bash

# Deletes files in /var/www/html/files older than 0 min (all non-backup files)

# Does NOT touch /share (backup copies remain)

FILES_DIR=”/var/www/html/files”
LOG=”/var/log/cleanup_files.log”
DATE=$(date ‘+%Y-%m-%d %H:%M:%S’)

echo “[$DATE] Cleanup started.” >> “$LOG”
DELETED=0
for f in “$FILES_DIR”/*; do
[[ -f “$f” ]] || continue
rm -f “$f”
echo “[$DATE] Deleted: $(basename “$f”)” >> “$LOG”
((DELETED++))
done
echo “[$DATE] Cleanup finished. Files removed: $DELETED” >> “$LOG”
CLEANEOF
chmod +x “$CLEANUP_SCRIPT”
info “Cleanup script: $CLEANUP_SCRIPT”

# =============================================================================

# Add all CRON jobs (Tasks 7, 8, 9)

# =============================================================================

info “=== Adding CRON jobs ===”
(crontab -l 2>/dev/null | grep -v rsync_backup | grep -v server_monitor | grep -v cleanup_files
echo “*/5  * * * * /usr/local/bin/rsync_backup.sh        # Task 7: rsync every 5 min”
echo “*/5  * * * * $MONITOR_SCRIPT                        # Task 8: monitor every 5 min”
echo “*/10 * * * * $CLEANUP_SCRIPT                        # Task 9: cleanup every 10 min”
) | crontab -
info “Cron jobs added (rsync: 5 min, monitor: 5 min, cleanup: 10 min)”

# =============================================================================

# TASK 10 — HTTP Basic Authentication on /var/www/html/files via HTTPD

# =============================================================================

info “=== TASK 10: Configuring HTTP Basic Authentication ===”
$PKG_INSTALL apache2-utils 2>/dev/null || $PKG_INSTALL httpd-tools 2>/dev/null || true

HTPASSWD_FILE=”/etc/httpd/.htpasswd”
[[ “$HTTPD_SERVICE” == “apache2” ]] && HTPASSWD_FILE=”/etc/apache2/.htpasswd”

htpasswd -bc “$HTPASSWD_FILE” “$HTPASSWD_USER” “$HTPASSWD_PASS”
chmod 640 “$HTPASSWD_FILE”

# Apache vhost / directory config

if [[ “$HTTPD_SERVICE” == “apache2” ]]; then
CONF_FILE=”/etc/apache2/conf-available/files-auth.conf”
cat > “$CONF_FILE” <<CONFEOF
<Directory /var/www/html/files>
AuthType Basic
AuthName “Restricted Files”
AuthUserFile $HTPASSWD_FILE
Require valid-user
Options +Indexes
AllowOverride None
</Directory>
CONFEOF
a2enconf files-auth
# Ensure AllowOverride is at least AuthConfig for /var/www/html
sed -i ‘s/AllowOverride None/AllowOverride AuthConfig/g’ /etc/apache2/apache2.conf 2>/dev/null || true
systemctl restart apache2
else
CONF_FILE=”/etc/httpd/conf.d/files-auth.conf”
cat > “$CONF_FILE” <<CONFEOF
<Directory /var/www/html/files>
AuthType Basic
AuthName “Restricted Files”
AuthUserFile $HTPASSWD_FILE
Require valid-user
Options +Indexes
AllowOverride None
</Directory>
CONFEOF
systemctl restart httpd
fi
info “HTTP Basic Auth enabled on /files.  User: $HTPASSWD_USER  Pass: $HTPASSWD_PASS”

# =============================================================================

# Open firewall ports (if firewalld or ufw present)

# =============================================================================

info “=== Configuring firewall ===”
if command -v firewall-cmd &>/dev/null; then
firewall-cmd –permanent –add-service=http
firewall-cmd –permanent –add-service=https
firewall-cmd –permanent –add-service=samba
firewall-cmd –reload
info “firewalld: HTTP, HTTPS, Samba opened.”
elif command -v ufw &>/dev/null; then
ufw allow ‘Apache Full’
ufw allow samba
info “ufw: Apache Full, Samba allowed.”
else
warn “No firewall manager found — open ports 80, 443, 137-139, 445 manually.”
fi

# =============================================================================

# DONE — Summary

# =============================================================================

echo “”
echo -e “${GREEN}=================================================================${NC}”
echo -e “${GREEN}  SERVER SETUP COMPLETE${NC}”
echo -e “${GREEN}=================================================================${NC}”
echo “”
echo “  [1] Apache (HTTPD)    : running  — http://<server-ip>/”
echo “  [2] SAMBA             : running  — \\<server-ip>\webshare”
echo “      Samba user/pass   : $SAMBA_USER / $SAMBA_PASS”
echo “  [3] PHP               : installed”
echo “  [4] OpenSSL helpers   : encrypt_file.sh / decrypt_file.sh”
echo “      Encryption pass   : stored in /etc/openssl_enc.pass”
echo “  [5] PHP file site     : http://<server-ip>/  (upload + download)”
echo “  [6] /share dir        : ready (backup destination)”
echo “  [7] rsync watcher     : systemd service rsync-watch + cron every 5 min”
echo “  [8] Monitor script    : $MONITOR_SCRIPT  (cron every 5 min)”
echo “      Monitor log       : /var/log/server_monitor.log”
echo “  [9] Cleanup script    : $CLEANUP_SCRIPT  (cron every 10 min)”
echo “      Cleanup log       : /var/log/cleanup_files.log”
echo “ [10] HTTP Basic Auth   : /files protected”
echo “      Auth user/pass    : $HTPASSWD_USER / $HTPASSWD_PASS”
echo “”
echo -e “${YELLOW}  ⚠  Change default passwords in the script before production use!${NC}”
echo -e “${GREEN}=================================================================${NC}”
