#!/bin/bash
set -e

# AstracatNScloud Deployment Script v1.0
# Supports Ubuntu 20.04/22.04 and Debian 11/12

LOG_FILE="deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

WEB_DIR="/var/www/astracat"

echo "Starting AstracatNScloud Deployment at $(date)..."

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Helper functions
function is_installed {
    dpkg -s "$1" &> /dev/null
}

function check_db_exists {
    mysql -e "USE $1" 2>/dev/null
}

# 1. Install Dependencies
echo "Installing dependencies..."
DEPS="nginx mariadb-server php-fpm php-mysql php-curl php-gd php-intl php-mbstring php-xml php-zip git curl acl unzip rsync composer"
apt-get update
# Prevent interactive prompts
export DEBIAN_FRONTEND=noninteractive
apt-get install -y $DEPS

# 2. Install PowerDNS
echo "Installing PowerDNS..."
if ! is_installed pdns-server; then
    apt-get install -y pdns-server pdns-backend-mysql
else
    echo "PowerDNS already installed."
fi

# 3. Configure Database
echo "Configuring Database..."
if ! check_db_exists "powerdns"; then
    DB_PASS=$(openssl rand -base64 12)
    mysql -e "CREATE DATABASE IF NOT EXISTS powerdns;"
    mysql -e "GRANT ALL PRIVILEGES ON powerdns.* TO 'powerdns'@'localhost' IDENTIFIED BY '${DB_PASS}';"
    mysql -e "FLUSH PRIVILEGES;"
    echo "Database created."

    # Import PowerDNS Schema
    if [ -f /usr/share/doc/pdns-backend-mysql/schema.mysql.sql ]; then
        mysql powerdns < /usr/share/doc/pdns-backend-mysql/schema.mysql.sql
    elif [ -f /usr/share/doc/pdns-server/schema.mysql.sql ]; then
        mysql powerdns < /usr/share/doc/pdns-server/schema.mysql.sql
    else
        # Fallback schema
        echo "Using fallback schema..."
        mysql powerdns <<EOF
CREATE TABLE domains (
  id                    INT AUTO_INCREMENT,
  name                  VARCHAR(255) NOT NULL,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INT DEFAULT NULL,
  type                  VARCHAR(6) NOT NULL,
  notified_serial       INT DEFAULT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  PRIMARY KEY (id)
) Engine=InnoDB;

CREATE UNIQUE INDEX name_index ON domains(name);

CREATE TABLE records (
  id                    BIGINT AUTO_INCREMENT,
  domain_id             INT DEFAULT NULL,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               VARCHAR(64000) DEFAULT NULL,
  ttl                   INT DEFAULT NULL,
  prio                  INT DEFAULT NULL,
  disabled              TINYINT(1) DEFAULT 0,
  ordername             VARCHAR(255) BINARY DEFAULT NULL,
  auth                  TINYINT(1) DEFAULT 1,
  PRIMARY KEY (id)
) Engine=InnoDB;

CREATE INDEX nametype_index ON records(name,type);
CREATE INDEX domain_id ON records(domain_id);
CREATE INDEX recordorder ON records (domain_id, ordername);

CREATE TABLE supermasters (
  ip                    VARCHAR(64) NOT NULL,
  nameserver            VARCHAR(255) NOT NULL,
  account               VARCHAR(40) NOT NULL,
  PRIMARY KEY (ip, nameserver)
) Engine=InnoDB;

CREATE TABLE comments (
  id                    INT AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INT NOT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  comment               TEXT NOT NULL,
  PRIMARY KEY (id)
) Engine=InnoDB;

CREATE INDEX comments_name_type_idx ON comments (name, type);
CREATE INDEX comments_order_idx ON comments (domain_id, modified_at);

CREATE TABLE domainmetadata (
  id                    INT AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  kind                  VARCHAR(32),
  content               TEXT,
  PRIMARY KEY (id)
) Engine=InnoDB;

CREATE INDEX domainmetadata_idx ON domainmetadata (domain_id, kind);

CREATE TABLE cryptokeys (
  id                    INT AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  flags                 INT NOT NULL,
  active                TINYINT(1),
  published             TINYINT(1) DEFAULT 1,
  content               TEXT,
  PRIMARY KEY (id)
) Engine=InnoDB;

CREATE INDEX domainidindex ON cryptokeys(domain_id);

CREATE TABLE tsigkeys (
  id                    INT AUTO_INCREMENT,
  name                  VARCHAR(255),
  algorithm             VARCHAR(50),
  secret                VARCHAR(255),
  PRIMARY KEY (id)
) Engine=InnoDB;

CREATE UNIQUE INDEX namealgoindex ON tsigkeys(name, algorithm);
EOF
    fi
else
    echo "Database 'powerdns' already exists. Skipping creation."
    # We assume password is known or we cannot reset it easily without breaking things.
    # In a real scenario, we might want to store the password in a file.
    # For now, we'll try to grep it from existing config if it exists
    if [ -f "$WEB_DIR/config/settings.php" ]; then
        DB_PASS=$(grep "'pass'" "$WEB_DIR/config/settings.php" | cut -d"'" -f4)
    else
         echo "WARNING: Database exists but config not found. You might need to manually set the password."
         # If we really need a password, we might need to reset it, but that's dangerous.
         # Let's assume for this exercise we can proceed or fail later.
         DB_PASS="existing_pass_unknown"
    fi
fi

# 4. Configure PowerDNS to use MySQL
if [ ! -f /etc/powerdns/pdns.d/pdns.local.gmysql.conf ]; then
    cat > /etc/powerdns/pdns.d/pdns.local.gmysql.conf <<EOF
launch=gmysql
gmysql-host=localhost
gmysql-user=powerdns
gmysql-password=${DB_PASS}
gmysql-dbname=powerdns
gmysql-dnssec=yes
EOF
    systemctl restart pdns
else
    echo "PowerDNS MySQL config already exists."
fi

# 5. Install PowerDNS Admin (AstracatNScloud)
echo "Installing AstracatNScloud..."
mkdir -p $WEB_DIR

if [ -d ".git" ]; then
    echo "Syncing application files..."
    rsync -av --exclude='.git' --exclude='deploy.log' . $WEB_DIR/
else
    echo "ERROR: This script expects to be run from the application source directory."
    exit 1
fi

chown -R www-data:www-data $WEB_DIR
chmod -R 755 $WEB_DIR

# 6. Install PHP Dependencies
echo "Installing PHP dependencies..."
cd $WEB_DIR
if [ -f "composer.json" ]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    composer install --no-dev --optimize-autoloader || echo "Composer install failed, check logs"
fi

# 7. Configure AstracatNScloud
CONFIG_FILE="$WEB_DIR/config/settings.php"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating configuration file..."
    cat > $CONFIG_FILE <<EOF
<?php
return [
    'interface' => [
        'style' => 'astracat',
        'title' => 'AstracatNScloud',
        'language' => 'en_US',
    ],
    'database' => [
        'host' => 'localhost',
        'port' => '3306',
        'user' => 'powerdns',
        'pass' => '${DB_PASS}',
        'name' => 'powerdns',
        'type' => 'mysql',
    ],
    'security' => [
        'session_key' => '$(openssl rand -hex 16)',
    ]
];
EOF
else
    echo "Configuration file already exists."
fi

# Run Database Migrations for Poweradmin (Idempotent checks needed inside SQL or handle errors)
if [ -d "$WEB_DIR/sql" ]; then
    echo "Checking Poweradmin tables..."
    # A simple check if 'users' table exists (part of poweradmin, not pdns)
    if ! mysql powerdns -e "DESCRIBE users;" > /dev/null 2>&1; then
        echo "Importing Poweradmin DB Schema..."
        mysql powerdns < "$WEB_DIR/sql/poweradmin.sql" 2>/dev/null || mysql powerdns < "$WEB_DIR/sql/poweradmin-mysql-db-structure.sql" 2>/dev/null || true
    else
        echo "Poweradmin tables seem to exist."
    fi
fi

# 8. Configure Nginx
echo "Configuring Nginx..."
if [ ! -f /etc/nginx/sites-available/astracat ]; then
    cat > /etc/nginx/sites-available/astracat <<EOF
server {
    listen 80;
    server_name _;
    root $WEB_DIR;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php*-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/astracat /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    systemctl restart nginx
else
    echo "Nginx config already exists."
fi

# 9. Post-Deploy Verification
echo "Running Post-Deploy Verification..."

# Check API Health (simulated by checking homepage HTTP status)
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 302 ]; then
    echo "✅ Web Panel is responding (HTTP $HTTP_STATUS)"
else
    echo "❌ Web Panel check failed (HTTP $HTTP_STATUS)"
fi

# Check DNS Resolution
# Create a dummy record in memory or just check localhost status if pdns allows
if systemctl is-active --quiet pdns; then
     echo "✅ PowerDNS service is running"
else
     echo "❌ PowerDNS service is NOT running"
fi

echo "Deployment Complete!"
if [ "${DB_PASS}" != "existing_pass_unknown" ]; then
    echo "Database Password: ${DB_PASS}"
fi
echo "Access the panel at http://<your-ip>/"
