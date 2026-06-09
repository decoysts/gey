#!/bin/bash

# ==============================================================================
# PRO-AUTOMATION SCRIPT FOR LAB ENVIRONMENT (CentOS 7 EOL)
# ==============================================================================
# Этот скрипт настроен на максимальную автономность.
# Все настройки вынесены в блок переменных ниже.
# ==============================================================================

set -e # Прерывание при любой ошибке

# --- НАСТРОЙКИ (VARIABLES) ---
DB_ROOT_PASS="RootSecurePass2026"
WP_DB="wordpress"
WP_USER="wp_admin"
WP_PASS="WpSuperPass123"

JOOMLA_DB="joomla"
JOOMLA_USER="jm_admin"
JOOMLA_PASS="JmSuperPass123"

GRAFANA_USER="grafana_reader"
GRAFANA_PASS="GrafanaRead456"

SMB_USER="smbuser"
SMB_PASS="smbpassword"
# -----------------------------

# --- ЦВЕТА ДЛЯ ЛОГОВ ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
info "Перенаправление репозиториев CentOS 7 на Vault..."
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
yum clean all > /dev/null 2>&1
rm -rf /var/cache/yum

info "Установка базовых пакетов и EPEL..."
yum update -y -q
yum install -y -q epel-release wget unzip curl net-tools git vim

info "Отключение SELinux (для корректной работы Samba и Apache в лабе)..."
setenforce 0 || true
sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
success "Система подготовлена."

# ==============================================================================
# 1. LAMP СТЕК: APACHE, PHP 7.4, MARIADB
# ==============================================================================
info "Установка стека LAMP (PHP 7.4 через Remi)..."
yum install -y -q https://rpms.remirepo.net/enterprise/remi-release-7.rpm
yum-config-manager --enable remi-php74 > /dev/null
yum install -y -q httpd mariadb-server mariadb php php-cli php-mysqlnd php-gd php-mbstring php-xml php-json php-zip

systemctl enable --now httpd mariadb > /dev/null

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
wget -qO /tmp/latest.tar.gz https://wordpress.org/latest.tar.gz
tar -xzf /tmp/latest.tar.gz -C /var/www/html/

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
wget -qO /tmp/joomla.zip https://github.com/joomla/joomla-cms/releases/download/3.10.12/Joomla_3.10.12-Stable-Full_Package.zip
unzip -q /tmp/joomla.zip -d /var/www/html/joomla/

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
yum install -y -q samba samba-client
mv /etc/samba/smb.conf /etc/samba/smb.conf.bak || true

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

useradd -M -s /sbin/nologin ${SMB_USER} || true
(echo "${SMB_PASS}"; echo "${SMB_PASS}") | smbpasswd -s -a ${SMB_USER} > /dev/null

systemctl enable --now smb nmb > /dev/null
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
WP_ARCH=\$(ls -t /share/backups/wp_backup_*.tar.gz | head -n1)
WP_SQL=\$(ls -t /share/backups/wp_db_*.sql | head -n1)
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
wget -q https://dl.grafana.com/oss/release/grafana-10.0.3-1.x86_64.rpm
yum localinstall -y -q grafana-10.0.3-1.x86_64.rpm > /dev/null

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

systemctl enable --now grafana-server > /dev/null
success "Мониторинг Grafana активирован."

# ==============================================================================
# 7. DOCKER СТЕК
# ==============================================================================
info "Развертывание контейнерной среды Docker..."
yum install -y -q yum-utils device-mapper-persistent-data lvm2
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null
yum install -y -q docker-ce docker-ce-cli containerd.io

systemctl enable --now docker > /dev/null

mkdir -p /var/www/docker-hello
echo "<h1 style='font-family: monospace; color: green; background: black; padding: 20px;'>> DOCKER CONTAINER HTTPD UP AND RUNNING</h1>" > /var/www/docker-hello/index.html

docker run -d --name lab-apache-node -p 8080:80 -v /var/www/docker-hello:/usr/local/apache2/htdocs/ --restart unless-stopped httpd:alpine > /dev/null
success "Docker контейнер запущен на порту 8080."

# ==============================================================================
# 8. БЕЗОПАСНОСТЬ (FIREWALL)
# ==============================================================================
info "Настройка сетевого экрана (Firewalld)..."
yum install -y -q firewalld
systemctl enable --now firewalld > /dev/null

firewall-cmd --permanent --zone=public --add-service=http > /dev/null
firewall-cmd --permanent --zone=public --add-service=samba > /dev/null
firewall-cmd --permanent --zone=public --add-port=3000/tcp > /dev/null
firewall-cmd --permanent --zone=public --add-port=8080/tcp > /dev/null
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
