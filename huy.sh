#!/bin/bash
# Full Server Setup — CentOS 7
# Запуск: bash server_setup.sh

LOG="/var/log/server_setup.log"
touch "$LOG"
info()  { echo "[INFO]  $1" | tee -a "$LOG"; }
warn()  { echo "[WARN]  $1" | tee -a "$LOG"; }
error() { echo "[ERROR] $1" | tee -a "$LOG"; exit 1; }

[ "$(id -u)" -ne 0 ] && error "Запустите от root: bash $0"

# ── Пароли — СМЕНИТЕ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────────
WEB_ROOT="/var/www/html"
FILES_DIR="$WEB_ROOT/files"
SHARE_DIR="/share"
SAMBA_USER="sambauser"
SAMBA_PASS="SambaPass123"
ENC_PASS="EncryptPass456"
HTPASSWD_USER="admin"
HTPASSWD_PASS="AdminPass789"
MONITOR_SCRIPT="/usr/local/bin/server_monitor.sh"
CLEANUP_SCRIPT="/usr/local/bin/cleanup_files.sh"

# ── TASK 1: HTTPD ─────────────────────────────────────────────────────────────
info "=== TASK 1: HTTPD ==="
yum install -y httpd
systemctl enable httpd
systemctl start  httpd

# ── TASK 2: SAMBA ─────────────────────────────────────────────────────────────
info "=== TASK 2: SAMBA ==="
yum install -y samba samba-client samba-common

id "$SAMBA_USER" >/dev/null 2>&1 || useradd -M -s /sbin/nologin "$SAMBA_USER"
printf "%s\n%s\n" "$SAMBA_PASS" "$SAMBA_PASS" | smbpasswd -a -s "$SAMBA_USER"
smbpasswd -e "$SAMBA_USER"

cp /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

printf '\n[webshare]\n   comment = Web HTML Share\n   path = /var/www/html\n   browseable = yes\n   read only = no\n   valid users = %s\n   create mask = 0664\n   directory mask = 0775\n' "$SAMBA_USER" >> /etc/samba/smb.conf

systemctl enable smb nmb
systemctl restart smb nmb

# ── TASK 3: PHP ───────────────────────────────────────────────────────────────
info "=== TASK 3: PHP ==="
yum install -y php php-cli php-common
systemctl restart httpd

# ── TASK 4: OpenSSL ───────────────────────────────────────────────────────────
info "=== TASK 4: OpenSSL ==="
yum install -y openssl
echo "$ENC_PASS" > /etc/openssl_enc.pass
chmod 600 /etc/openssl_enc.pass

printf '#!/bin/bash\nSRC="$1"\nOUT_DIR="${2:-/var/www/html/files}"\n[ -z "$SRC" ] || [ ! -f "$SRC" ] && { echo "Usage: $0 <file> [dir]"; exit 1; }\nPASS=$(cat /etc/openssl_enc.pass)\nmkdir -p "$OUT_DIR"\nNAME=$(basename "$SRC")\nopenssl enc -aes-256-cbc -pbkdf2 -in "$SRC" -out "$OUT_DIR/${NAME}.enc" -pass "pass:$PASS"\necho "Зашифровано: $OUT_DIR/${NAME}.enc"\n' > /usr/local/bin/encrypt_file.sh

printf '#!/bin/bash\nSRC="$1"\nOUT_DIR="${2:-.}"\n[ -z "$SRC" ] || [ ! -f "$SRC" ] && { echo "Usage: $0 <file.enc> [dir]"; exit 1; }\nPASS=$(cat /etc/openssl_enc.pass)\nmkdir -p "$OUT_DIR"\nNAME=$(basename "$SRC" .enc)\nopenssl enc -d -aes-256-cbc -pbkdf2 -in "$SRC" -out "$OUT_DIR/$NAME" -pass "pass:$PASS"\necho "Расшифровано: $OUT_DIR/$NAME"\n' > /usr/local/bin/decrypt_file.sh

chmod +x /usr/local/bin/encrypt_file.sh /usr/local/bin/decrypt_file.sh

# ── TASK 5: PHP сайт ──────────────────────────────────────────────────────────
info "=== TASK 5: PHP сайт ==="
mkdir -p "$FILES_DIR"
chown -R apache:apache "$FILES_DIR"
chmod 775 "$FILES_DIR"

# PHP файл закодирован в base64 — единственный надёжный способ
# избежать конфликтов bash с ?> $_ && { символами
echo "PD9waHAKJGZpbGVzX2RpciA9IF9fRElSX18gLiAiL2ZpbGVzIjsKJG1lc3NhZ2UgPSAiIjsKaWYgKCRfU0VSVkVSWyJSRVFVRVNUX01FVEhPRCJdID09PSAiUE9TVCIgJiYgaXNzZXQoJF9GSUxFU1sidXBsb2FkIl0pKSB7CiAgICAkcGFzcyA9IHRyaW0oZmlsZV9nZXRfY29udGVudHMoIi9ldGMvb3BlbnNzbF9lbmMucGFzcyIpKTsKICAgICR0bXAgID0gJF9GSUxFU1sidXBsb2FkIl1bInRtcF9uYW1lIl07CiAgICAkbmFtZSA9IGJhc2VuYW1lKCRfRklMRVNbInVwbG9hZCJdWyJuYW1lIl0pOwogICAgJG91dCAgPSAkZmlsZXNfZGlyIC4gIi8iIC4gJG5hbWUgLiAiLmVuYyI7CiAgICAkY21kICA9ICJvcGVuc3NsIGVuYyAtYWVzLTI1Ni1jYmMgLXBia2RmMiAtaW4gIiAuIGVzY2FwZXNoZWxsYXJnKCR0bXApCiAgICAgICAgICAuICIgLW91dCAiIC4gZXNjYXBlc2hlbGxhcmcoJG91dCkKICAgICAgICAgIC4gIiAtcGFzcyBwYXNzOiIgLiBlc2NhcGVzaGVsbGFyZygkcGFzcykgLiAiIDI+JjEiOwogICAgZXhlYygkY21kLCAkcmVzLCAkcmMpOwogICAgJG9rID0gKCRyYyA9PT0gMCk7CiAgICAkY2wgPSAkb2sgPyAiZ3JlZW4iIDogInJlZCI7CiAgICAkdHggPSAkb2sgPyAi0JfQsNCz0YDRg9C20LXQvdC+OiAiIC4gaHRtbHNwZWNpYWxjaGFycygkbmFtZSkgLiAiLmVuYyIgOiBpbXBsb2RlKCIgIiwgJHJlcyk7CiAgICAkbWVzc2FnZSA9ICI8cCBzdHlsZT1cImNvbG9yOiRjbFwiPiR0eDwvcD4iOwp9Cj8+CjwhRE9DVFlQRSBodG1sPgo8aHRtbCBsYW5nPSJydSI+CjxoZWFkPgo8bWV0YSBjaGFyc2V0PSJVVEYtOCI+Cjx0aXRsZT7QpNCw0LnQu9C+0LLRi9C5INGB0LXRgNCy0LXRgDwvdGl0bGU+CjxzdHlsZT4KKntib3gtc2l6aW5nOmJvcmRlci1ib3g7bWFyZ2luOjA7cGFkZGluZzowfQpib2R5e2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXNpemU6MTRweDtiYWNrZ3JvdW5kOiNmZmY7Y29sb3I6IzExMTtwYWRkaW5nOjMwcHg7bWF4LXdpZHRoOjg2MHB4fQpoMXtmb250LXNpemU6MTZweDttYXJnaW4tYm90dG9tOjIwcHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2JiYjtwYWRkaW5nLWJvdHRvbTo4cHh9Cmgye2ZvbnQtc2l6ZToxM3B4O21hcmdpbjoyMHB4IDAgNnB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjb2xvcjojNTU1fQp0YWJsZXt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZX0KdGgsdGR7cGFkZGluZzo1cHggOHB4O2JvcmRlcjoxcHggc29saWQgI2NjYzt0ZXh0LWFsaWduOmxlZnR9CnRoe2JhY2tncm91bmQ6I2YwZjBmMH0KYXtjb2xvcjojMDBlfQoucm93e2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlcjttYXJnaW4tYm90dG9tOjRweH0KaW5wdXRbdHlwZT1zdWJtaXRde3BhZGRpbmc6NHB4IDEycHg7Y3Vyc29yOnBvaW50ZXJ9CnNtYWxse2NvbG9yOiM5OTl9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CjxoMT7QpNCw0LnQu9C+0LLRi9C5INGB0LXRgNCy0LXRgDwvaDE+CjxoMj7Ql9Cw0LPRgNGD0LfQuNGC0Ywg0YTQsNC50Ls8L2gyPgo8Zm9ybSBtZXRob2Q9IlBPU1QiIGVuY3R5cGU9Im11bHRpcGFydC9mb3JtLWRhdGEiPgo8ZGl2IGNsYXNzPSJyb3ciPgo8aW5wdXQgdHlwZT0iZmlsZSIgbmFtZT0idXBsb2FkIiByZXF1aXJlZD4KPGlucHV0IHR5cGU9InN1Ym1pdCIgdmFsdWU9ItCX0LDQs9GA0YPQt9C40YLRjCDQuCDQt9Cw0YjQuNGE0YDQvtCy0LDRgtGMIj4KPC9kaXY+CjwvZm9ybT4KPD9waHAgZWNobyAkbWVzc2FnZTsgPz4KPGgyPtCh0L/QuNGB0L7QuiDRhNCw0LnQu9C+0LI8L2gyPgo8dGFibGU+Cjx0cj48dGg+0JjQvNGPINGE0LDQudC70LA8L3RoPjx0aD7QoNCw0LfQvNC10YA8L3RoPjx0aD7QmNC30LzQtdC90ZDQvTwvdGg+PHRoPtCh0LrQsNGH0LDRgtGMPC90aD48L3RyPgo8P3BocAokZmlsZXMgPSBnbG9iKCRmaWxlc19kaXIgLiAiLyoiKTsKaWYgKGVtcHR5KCRmaWxlcykpIHsgZWNobyAiPHRyPjx0ZCBjb2xzcGFuPTQ+0KTQsNC50LvQvtCyINC90LXRgi48L3RkPjwvdHI+IjsgfQplbHNlIHsKICBmb3JlYWNoICgkZmlsZXMgYXMgJGYpIHsKICAgICRubSAgPSBiYXNlbmFtZSgkZik7CiAgICAkc3ogID0gcm91bmQoZmlsZXNpemUoJGYpLzEwMjQsMikuIiDQmtCRIjsKICAgICRtdCAgPSBkYXRlKCJkLm0uWSBIOmkiLCBmaWxlbXRpbWUoJGYpKTsKICAgICR1cmwgPSAiZmlsZXMvIi5yYXd1cmxlbmNvZGUoJG5tKTsKICAgIGVjaG8gIjx0cj48dGQ+Ii5odG1sc3BlY2lhbGNoYXJzKCRubSkuIjwvdGQ+PHRkPiRzejwvdGQ+PHRkPiRtdDwvdGQ+PHRkPjxhIGhyZWY9XCIkdXJsXCI+0YHQutCw0YfQsNGC0Yw8L2E+PC90ZD48L3RyPiI7CiAgfQp9Cj8+CjwvdGFibGU+Cjxicj48c21hbGw+QUVTLTI1Ni1DQkMuINCg0LDRgdGI0LjRhNGA0L7QstC60LA6IGRlY3J5cHRfZmlsZS5zaCDRhNCw0LnQuy5lbmM8L3NtYWxsPgo8L2JvZHk+PC9odG1sPgo=" | base64 -d > "$WEB_ROOT/index.php"

systemctl restart httpd

# ── TASK 6: /share ────────────────────────────────────────────────────────────
info "=== TASK 6: /share ==="
mkdir -p "$SHARE_DIR"
chmod 775 "$SHARE_DIR"

# ── TASK 7: rsync ─────────────────────────────────────────────────────────────
info "=== TASK 7: rsync ==="
yum install -y rsync

printf '#!/bin/bash\nSRC="/var/www/html/files/"\nDST="/share/"\nLOG="/var/log/rsync_backup.log"\necho "$(date +%%Y-%%m-%%d\\ %%H:%%M:%%S) start" >> "$LOG"\nrsync -av --delete "$SRC" "$DST" >> "$LOG" 2>&1\necho "$(date +%%Y-%%m-%%d\\ %%H:%%M:%%S) done" >> "$LOG"\n' > /usr/local/bin/rsync_backup.sh
chmod +x /usr/local/bin/rsync_backup.sh

yum install -y epel-release 2>/dev/null || true
yum install -y inotify-tools 2>/dev/null || warn "inotify-tools недоступен, только cron"

if command -v inotifywait >/dev/null 2>&1; then
    printf '#!/bin/bash\nwhile true; do\n    inotifywait -r -e create,modify,delete,moved_to /var/www/html/files 2>/dev/null\n    /usr/local/bin/rsync_backup.sh\ndone\n' > /usr/local/bin/rsync_watch.sh
    chmod +x /usr/local/bin/rsync_watch.sh

    printf '[Unit]\nDescription=Rsync watcher\nAfter=network.target\n\n[Service]\nExecStart=/usr/local/bin/rsync_watch.sh\nRestart=always\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/rsync-watch.service

    systemctl daemon-reload
    systemctl enable rsync-watch
    systemctl start  rsync-watch
    info "inotify watcher запущен."
fi

# ── TASK 8: Мониторинг ────────────────────────────────────────────────────────
info "=== TASK 8: Мониторинг ==="
yum install -y sysstat lm_sensors 2>/dev/null || true

cat > "$MONITOR_SCRIPT" <<'MONEOF'
#!/bin/bash
LOG="/var/log/server_monitor.log"
DT=$(date +"%Y-%m-%d %H:%M:%S")
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | tr -d '%us,')
RAM_T=$(free -m | awk '/^Mem/{print $2}')
RAM_U=$(free -m | awk '/^Mem/{print $3}')
RAM_F=$(free -m | awk '/^Mem/{print $4}')
DISK_U=$(df -h / | awk 'NR==2{print $3}')
DISK_F=$(df -h / | awk 'NR==2{print $4}')
DISK_P=$(df -h / | awk 'NR==2{print $5}')
if command -v sensors >/dev/null 2>&1; then
    CPU_T=$(sensors 2>/dev/null | awk '/Core 0|Package/{print $3; exit}')
else
    CPU_T=$(awk '{printf "%.1f C",$1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo N/A)
fi
if command -v smartctl >/dev/null 2>&1; then
    SSD_T=$(smartctl -A /dev/sda 2>/dev/null | awk '/Temperature_Celsius/{print $10" C"}' || echo N/A)
else
    SSD_T="N/A"
fi
echo "[$DT] CPU:${CPU}% RAM:${RAM_U}/${RAM_T}MB(free:${RAM_F}) Disk:${DISK_U}used/${DISK_F}free(${DISK_P}) CPU_T:${CPU_T} SSD_T:${SSD_T}" >> "$LOG"
MONEOF
chmod +x "$MONITOR_SCRIPT"

# ── TASK 9: Очистка ───────────────────────────────────────────────────────────
info "=== TASK 9: Очистка ==="
cat > "$CLEANUP_SCRIPT" <<'CLEANEOF'
#!/bin/bash
DIR="/var/www/html/files"
LOG="/var/log/cleanup_files.log"
DT=$(date +"%Y-%m-%d %H:%M:%S")
COUNT=0
for f in "$DIR"/*; do
    [ -f "$f" ] || continue
    rm -f "$f"
    echo "[$DT] Удалён: $(basename "$f")" >> "$LOG"
    COUNT=$((COUNT+1))
done
echo "[$DT] Готово. Удалено: $COUNT" >> "$LOG"
CLEANEOF
chmod +x "$CLEANUP_SCRIPT"

# ── CRON ──────────────────────────────────────────────────────────────────────
info "=== CRON ==="
crontab -l 2>/dev/null | grep -v rsync_backup | grep -v server_monitor | grep -v cleanup_files > /tmp/_cron || true
printf '*/5  * * * * /usr/local/bin/rsync_backup.sh\n*/5  * * * * %s\n*/10 * * * * %s\n' "$MONITOR_SCRIPT" "$CLEANUP_SCRIPT" >> /tmp/_cron
crontab /tmp/_cron
rm -f /tmp/_cron

# ── TASK 10: HTTP Basic Auth ──────────────────────────────────────────────────
info "=== TASK 10: HTTP Basic Auth ==="
yum install -y httpd-tools
htpasswd -bc /etc/httpd/.htpasswd "$HTPASSWD_USER" "$HTPASSWD_PASS"
chmod 640 /etc/httpd/.htpasswd

printf '<Directory /var/www/html/files>\n    AuthType Basic\n    AuthName "Restricted"\n    AuthUserFile /etc/httpd/.htpasswd\n    Require valid-user\n    Options +Indexes\n</Directory>\n' > /etc/httpd/conf.d/files-auth.conf

systemctl restart httpd

# ── Firewall ──────────────────────────────────────────────────────────────────
info "=== Firewall ==="
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http  2>/dev/null || true
    firewall-cmd --permanent --add-service=https 2>/dev/null || true
    firewall-cmd --permanent --add-service=samba 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

# ── SELinux ───────────────────────────────────────────────────────────────────
info "=== SELinux ==="
if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_unified 1 2>/dev/null || true
    chcon -Rt httpd_sys_rw_content_t "$FILES_DIR" 2>/dev/null || true
fi

# ── Итог ──────────────────────────────────────────────────────────────────────
echo ""
echo "================================================================="
echo "  ГОТОВО"
echo "================================================================="
echo "  [1]  Apache    : http://<ip>/"
echo "  [2]  SAMBA     : \\\\<ip>\\webshare  $SAMBA_USER / $SAMBA_PASS"
echo "  [3]  PHP       : установлен"
echo "  [4]  OpenSSL   : encrypt_file.sh / decrypt_file.sh"
echo "  [5]  Сайт      : http://<ip>/"
echo "  [6]  /share    : готов"
echo "  [7]  rsync     : каждые 5 мин + inotify"
echo "  [8]  Монитор   : /var/log/server_monitor.log"
echo "  [9]  Очистка   : /var/log/cleanup_files.log (каждые 10 мин)"
echo "  [10] BasicAuth : /files  $HTPASSWD_USER / $HTPASSWD_PASS"
echo "================================================================="
