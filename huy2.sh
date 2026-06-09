#!/bin/bash

# ==============================================================================
# PRO-AUTOMATION SCRIPT FOR LAB ENVIRONMENT (CentOS 7 EOL)
# ==============================================================================
set -e # Прерывание при критической ошибке

# --- НАСТРОЙКИ (VARIABLES) ---
DB_ROOT_PASS="123456Admin"
WP_DB="wordpress"
WP_USER="wp_admin"
WP_PASS="123456Admin"

JOOMLA_DB="joomla"
JOOMLA_USER="jm_admin"
JOOMLA_PASS="123456Admin"

GRAFANA_USER="grafana_reader"
GRAFANA_PASS="123456Admin"

SMB_USER="smbuser"
SMB_PASS="smbpassword"
# -----------------------------

# --- ЦВЕТА ДЛЯ ЛОГОВ ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

function info() { echo -e "${CYAN}[*] $1${NC}"; }
function success() { echo -e "${GREEN}[+] $1${NC}"; }
function error_log() { echo -e "${RED}[!] $1${NC}"; }

# Проверка на root
if [ "$EUID" -ne 0 ]; then 
  error_log "Скрипт должен быть запущен с правами root!"
  exit 1
fi

info "Инициализация среды развертывания..."

# ==============================================================================
# 0. ФИКС EOL И ПОДГОТОВКА СИСТЕМЫ
# ==============================================================================
info "Агрессивный фикс репозиториев для CentOS 7 EOL..."

# 1. Отключаем проверку SSL для yum (чтобы не было curl #35)
if ! grep -q "sslverify=false" /etc/yum.conf; then
    echo "sslverify=false" >> /etc/yum.conf
fi

# 2. Перенаправляем базовые репозитории на Vault
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*

# 3. Установка EPEL через архивную прямую ссылку (если не установлен)
if ! rpm -q epel-release > /dev/null; then
    info "Установка EPEL через архив..."
    wget -O /tmp/epel.rpm http://dl.fedoraproject.org/pub/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm || \
    wget -O /tmp/epel.rpm http://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-11.noarch.rpm
    yum install -y /tmp/epel.rpm --nogpgcheck
fi

# 4. Установка Remi репозитория (если не установлен)
if ! rpm -q remi-release > /dev/null; then
    info "Установка Remi репозитория..."
    yum install -y http://rpms.remirepo.net/enterprise/remi-release-7.rpm --nogpgcheck
fi

# Фиксим файлы репозиториев Remi и EPEL на прямые ссылки
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/remi*.repo /etc/yum.repos.d/epel*.repo || true
sed -i 's|#baseurl=http://rpms.remirepo.net|baseurl=http://rpms.remirepo.net|g' /etc/yum.repos.d/remi*.repo || true

# 5. Сброс кэша
yum clean all
rm -rf /var/cache/yum
yum makecache

# 6. Установка базовых утилит (проверяем каждую, чтобы не выбивало Error: Nothing to do)
info "Установка системных утилит..."
for pkg in wget unzip curl net-tools git vim yum-utils device-mapper-persistent-data lvm2; do
    rpm -q $pkg > /dev/null || yum install -y --setopt=timeout=60 $pkg
done

info "Отключение SELinux (для корректной работы Samba и Apache в лабе)..."
setenforce 0 || true
sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
success "Система подготовлена."

# ==============================================================================
# 1. LAMP СТЕК: APACHE, PHP 7.4, MARIADB
# ==============================================================================
info "Настройка PHP 7.4 и установка LAMP..."

# Включаем PHP 7.4 в менеджере репозиториев
yum-config-manager --enable remi-php74 > /dev/null

# Ставим стек веб-сервера
PACKAGES="httpd mariadb-server mariadb php php-cli php-mysqlnd php-gd php-mbstring php-xml php-json php-zip"
for pkg in $PACKAGES; do
    rpm -q $pkg > /dev/null || yum install -y --setopt=timeout=60 $pkg
done

systemctl enable --now httpd mariadb

info "Настройка баз данных и выдача прав..."
mysqladmin -u root password "${DB_ROOT_PASS}" || true

mysql -u root -p"${DB_ROOT_PASS}" <<EOF
CREATE DATABASE IF NOT EXISTS ${WP_DB};
GRANT ALL PRIVILEGES ON ${WP_DB}.* TO '${WP_USER}'@'localhost' IDENTIFIED BY '${WP_PASS}';

CREATE DATABASE IF NOT EXISTS ${JOOMLA_DB};
GRANT ALL PRIVILEGES ON ${JOOMLA_DB}.* TO '${JOOMLA_USER}'@'localhost' IDENTIFIED BY '${JOOMLA_PASS}';

GRANT SELECT ON *.* TO '${GRAFANA_USER}'@'localhost' IDENTIFIED BY '${GRAFANA_PASS}';
FLUSH PRIVILEGES;
EOF

info "Генерация тестовых данных для дашбордов Grafana..."
mysql -u root -p"${DB_ROOT_PASS}" ${WP_DB} -e "CREATE TABLE IF NOT EXISTS wp_posts (ID bigint(20) unsigned NOT NULL AUTO_INCREMENT, post_status varchar(20) NOT NULL DEFAULT 'publish', post_type varchar(20) NOT NULL DEFAULT 'post', PRIMARY KEY (ID));"
mysql -u root -p"${DB_ROOT_PASS}" ${WP_DB} -e "INSERT INTO wp_posts (post_status, post_type) VALUES ('publish', 'post'), ('publish', 'post'), ('publish', 'post');"

mysql -u root -p"${DB_ROOT_PASS}" ${JOOMLA_DB} -e "CREATE TABLE IF NOT EXISTS jos_content (id int(11) NOT NULL AUTO_INCREMENT, state tinyint(3) NOT NULL DEFAULT 1, title varchar(255), PRIMARY KEY (id));"
mysql -u root -p"${DB_ROOT_PASS}" ${JOOMLA_DB} -e "INSERT INTO jos_content (state, title) VALUES (1, 'Initial Setup'), (1, 'Root Access Granted');"
success "Базы данных развернуты."

# ==============================================================================
# 2. WORDPRESS И КАСТОМНАЯ ТЕМА
# ==============================================================================
info "Развертывание WordPress..."
if [ ! -d "/var/www/html/wordpress" ]; then
    wget -qO /tmp/latest.tar.gz https://wordpress.org/latest.tar.gz
    tar -xzf /tmp/latest.tar.gz -C /var/www/html/
fi

cat <<EOF > /var/www/html/wordpress/wp-config.php
<?php
define('DB_NAME', '${WP_DB}');
define('DB_USER', '${WP_USER}');
define('DB_PASSWORD', '${WP_PASS}');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');
\$table_prefix = 'wp_';
define('WP_DEBUG', false);
if (!defined('ABSOLUTE_PATH')) { define('ABSOLUTE_PATH', __DIR__ . '/'); }
require_once ABSOLUTE_PATH . 'wp-settings.php';
EOF

info "Создание авторской темы для WP (Dark Terminal Theme)..."
mkdir -p /var/www/html/wordpress/wp-content/themes/gothic-hacker
cat <<EOF > /var/www/html/wordpress/wp-content/themes/gothic-hacker/style.css
/*
Theme Name: Terminal Cyber Theme
Author: Egor Ostapenko
Version: 1.0.0
Description: Dark mode terminal-inspired template for lab infrastructure.
*/
body { background-color: #050505; color: #00FF41; font-family: 'Courier New', Courier, monospace; margin: 50px; }
h1 { border-bottom: 1px solid #00FF41; padding-bottom: 10px; }
.container { background: #111; padding: 20px; border-radius: 5px; box-shadow: 0 0 10px #00FF41; }
EOF

cat <<EOF > /var/www/html/wordpress/wp-content/themes/gothic-hacker/index.php
<?php get_header(); ?>
<div class="container">
    <h1>> SYSTEM_ACCESS_GRANTED</h1>
    <p>WordPress environment is successfully running on custom infrastructure.</p>
</div>
<?php get_footer(); ?>
EOF
success "WordPress настроен."

# ==============================================================================
# 3. JOOMLA И КАСТОМНАЯ ТЕМА
# ==============================================================================
info "Развертывание Joomla 3.x..."
mkdir -p /var/www/html/joomla
if [ ! -f "/var/www/html/joomla/index.php" ]; then
    wget -qO /tmp/joomla.zip https://github.com/joomla/joomla-cms/releases/download/3.10.12/Joomla_3.10.12-Stable-Full_Package.zip
    unzip -q /tmp/joomla.zip -d /var/www/html/joomla/
fi

info "Создание авторского шаблона для Joomla..."
mkdir -p /var/www/html/joomla/templates/gothic-joomla
cat <<EOF > /var/www/html/joomla/templates/gothic-joomla/templateDetails.xml
<?xml version="1.0" encoding="utf-8"?>
<extension version="3.0" type="template" client="site">
	<name>gothic-joomla</name>
	<version>1.0</version>
	<description>Cyberpunk Lab Template</description>
	<files><filename>index.php</filename><filename>templateDetails.xml</filename></files>
</extension>
EOF

cat <<EOF > /var/www/html/joomla/templates/gothic-joomla/index.php
<?php defined('_JEXEC') or die; ?>
<!DOCTYPE html>
<html>
<head>
    <title>Joomla Root Console</title>
    <style>
        body { background: #000; color: #0f0; font-family: monospace; text-align: center; margin-top: 20%; }
        .blink { animation: blinker 1s linear infinite; }
        @keyframes blinker { 50% { opacity: 0; } }
    </style>
</head>
<body>
    <h2>root@centos7-lab:~# ./joomla_start.sh</h2>
    <h3>> Execution successful <span class="blink">_</span></h3>
</body>
</html>
EOF

chown -R apache:apache /var/www/html/
chmod -R 755 /var/www/html/
success "Joomla настроена."

# ==============================================================================
# 4. SAMBA НАСТРОЙКА (ДОСТУП К ФАЙЛАМ CMS)
# ==============================================================================
info "Конфигурация сервера Samba..."
rpm -q samba || yum install -y -q samba samba-client
[ -f /etc/samba/smb.conf ] && mv /etc/samba/smb.conf /etc/samba/smb.conf.bak

cat <<EOF > /etc/samba/smb.conf
[global]
    workgroup = WORKGROUP
    server string = Lab Infrastructure %v
    netbios name = centos7-lab
    security = user
    map to guest = bad user
    dns proxy = no

[wordpress_core]
    path = /var/www/html/wordpress
    browsable = yes
    writable = yes
    valid users = ${SMB_USER}
    create mask = 0644
    directory mask = 0755

[joomla_core]
    path = /var/www/html/joomla
    browsable = yes
    writable = yes
    valid users = ${SMB_USER}
    create mask = 0644
    directory mask = 0755
EOF

id -u ${SMB_USER} >/dev/null 2>&1 || useradd -M -s /sbin/nologin ${SMB_USER}
(echo "${SMB_PASS}"; echo "${SMB_PASS}") | smbpasswd -s -a ${SMB_USER} > /dev/null

systemctl enable --now smb nmb
success "Samba-шары активированы."

# ==============================================================================
# 5. СКРИПТЫ РЕЗЕРВНОГО КОПИРОВАНИЯ (С ТАЙМСТАМПАМИ)
# ==============================================================================
info "Генерация shell-скриптов для бэкапа и восстановления..."
mkdir -p /share/backups

cat <<EOF > /root/backup_all.sh
#!/bin/bash
TS=\$(date +"%Y%m%d_%H%M%S")
echo "Начинаем резервное копирование..."
tar -czf /share/backups/wp_backup_\$TS.tar.gz -C /var/www/html wordpress
mysqldump -u root -p"${DB_ROOT_PASS}" ${WP_DB} > /share/backups/wp_db_\$TS.sql
tar -czf /share/backups/jm_backup_\$TS.tar.gz -C /var/www/html joomla
mysqldump -u root -p"${DB_ROOT_PASS}" ${JOOMLA_DB} > /share/backups/jm_db_\$TS.sql
echo "Бэкап завершен. Файлы лежат в /share/backups/"
EOF

cat <<EOF > /root/restore_latest.sh
#!/bin/bash
echo "Внимание! Это сотрет текущие данные и восстановит последние бэкапы."
WP_ARCH=\$(ls -t /share/backups/wp_backup_*.tar.gz 2>/dev/null | head -n1)
WP_SQL=\$(ls -t /share/backups/wp_db_*.sql 2>/dev/null | head -n1)
if [ -z "\$WP_ARCH" ]; then echo "Бэкапы не найдены!"; exit 1; fi
rm -rf /var/www/html/wordpress
tar -xzf \$WP_ARCH -C /var/www/html/
mysql -u root -p"${DB_ROOT_PASS}" ${WP_DB} < \$WP_SQL
chown -R apache:apache /var/www/html/wordpress
echo "Восстановление успешно завершено."
EOF

chmod +x /root/backup_all.sh /root/restore_latest.sh
success "Утилиты бэкапа созданы в /root/"

# ==============================================================================
# 6. GRAFANA: PROVISIONING ДАШБОРДОВ
# ==============================================================================
info "Развертывание и провижининг Grafana..."
if ! rpm -q grafana > /dev/null; then
    wget -q https://dl.grafana.com/oss/release/grafana-10.0.3-1.x86_64.rpm
    yum localinstall -y grafana-10.0.3-1.x86_64.rpm --nogpgcheck
fi

cat <<EOF > /etc/grafana/provisioning/datasources/cms_sources.yaml
apiVersion: 1
datasources:
  - name: WP_Database
    type: mysql
    url: localhost:3306
    database: ${WP_DB}
    user: ${GRAFANA_USER}
    secureJsonData:
      password: ${GRAFANA_PASS}
  - name: Joomla_Database
    type: mysql
    url: localhost:3306
    database: ${JOOMLA_DB}
    user: ${GRAFANA_USER}
    secureJsonData:
      password: ${GRAFANA_PASS}
EOF

mkdir -p /var/lib/grafana/dashboards
cat <<EOF > /etc/grafana/provisioning/dashboards/dashboards.yaml
apiVersion: 1
providers:
  - name: 'Infrastructure'
    orgId: 1
    folder: 'CMS Monitoring'
    type: file
    disableDeletion: false
    options:
      path: /var/lib/grafana/dashboards
EOF

cat <<EOF > /var/lib/grafana/dashboards/cms_stats.json
{
  "editable": false,
  "panels": [
    {
      "title": "Активные публикации WordPress",
      "type": "stat",
      "datasource": { "type": "mysql", "uid": "WP_Database" },
      "targets": [{ "rawSql": "SELECT COUNT(*) as value FROM wp_posts WHERE post_status='publish';", "format": "table", "refId": "A" }],
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 }
    },
    {
      "title": "Материалы Joomla",
      "type": "stat",
      "datasource": { "type": "mysql", "uid": "Joomla_Database" },
      "targets": [{ "rawSql": "SELECT COUNT(*) as value FROM jos_content WHERE state=1;", "format": "table", "refId": "B" }],
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 38,
  "style": "dark",
  "time": { "from": "now-1h", "to": "now" },
  "title": "CMS Live Statistics",
  "version": 1
}
EOF

systemctl enable --now grafana-server
success "Мониторинг Grafana активирован."

# ==============================================================================
# 7. DOCKER СТЕК
# ==============================================================================
info "Развертывание контейнерной среды Docker..."
if ! rpm -q docker-ce > /dev/null; then
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null
    yum install -y --setopt=timeout=60 docker-ce docker-ce-cli containerd.io
fi

systemctl enable --now docker

mkdir -p /var/www/docker-hello
echo "<h1 style='font-family: monospace; color: green; background: black; padding: 20px;'>> DOCKER CONTAINER HTTPD UP AND RUNNING</h1>" > /var/www/docker-hello/index.html

docker rm -f lab-apache-node >/dev/null 2>&1 || true
docker run -d --name lab-apache-node -p 8080:80 -v /var/www/docker-hello:/usr/local/apache2/htdocs/ --restart unless-stopped httpd:alpine > /dev/null
success "Docker контейнер запущен на порту 8080."

# ==============================================================================
# 8. БЕЗОПАСНОСТЬ (FIREWALL)
# ==============================================================================
info "Настройка сетевого экрана (Firewalld)..."
rpm -q firewalld || yum install -y firewalld
systemctl enable --now firewalld

firewall-cmd --permanent --zone=public --add-service=http > /dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --add-service=samba > /dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --add-port=3000/tcp > /dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --add-port=8080/tcp > /dev/null 2>&1 || true
firewall-cmd --reload > /dev/null

success "Правила Firewall применены."

echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${CYAN} ДЕПЛОЙ ИНФРАСТРУКТУРЫ УСПЕШНО ЗАВЕРШЕН ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e " [HTTP] WordPress:     http://$(hostname -I | awk '{print $1}')/wordpress"
echo -e " [HTTP] Joomla:        http://$(hostname -I | awk '{print $1}')/joomla"
echo -e " [HTTP] Docker Node:   http://$(hostname -I | awk '{print $1}'):8080"
echo -e " [MON]  Grafana:       http://$(hostname -I | awk '{print $1}'):3000 (admin/admin)"
echo -e " [SMB]  Samba Shares:  \\\\$(hostname -I | awk '{print $1}')\\wordpress_core"
echo -e "                       \\\\$(hostname -I | awk '{print $1}')\\joomla_core"
echo -e "                       (User: ${SMB_USER} / Pass: ${SMB_PASS})"
echo -e " [UTIL] Бэкап скрипты: /root/backup_all.sh и /root/restore_latest.sh"
echo -e "${GREEN}==============================================================================${NC}"
