#!/bin/bash
# ============================================================
# InterviewCoach — EC2 Bootstrap (Solution SANS Amplify)
# EC2 héberge : API .NET + Frontend Next.js + nginx
#
# À coller dans "Advanced Details → User data" lors du lancement EC2
# S'exécute UNE SEULE FOIS au premier démarrage
# Log : /var/log/user-data.log
# ============================================================
set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== [1/8] Mise à jour système ==="
dnf update -y

echo "=== [2/8] Swap 1 GB (compensation RAM t2.micro 1 GB) ==="
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo "=== [3/8] Installation .NET 10 runtime ==="
dnf install -y dotnet-runtime-10.0
dotnet --version

echo "=== [4/8] Installation Node.js 20 (pour Next.js standalone) ==="
dnf install -y nodejs npm
node --version
npm --version

echo "=== [5/8] Installation nginx ==="
dnf install -y nginx
systemctl enable nginx

echo "=== [6/8] Utilisateurs système et répertoires ==="
useradd --system --no-create-home --shell /bin/false interviewcoach-api || true
useradd --system --no-create-home --shell /bin/false interviewcoach-web || true

mkdir -p /opt/interviewcoach/api
mkdir -p /opt/interviewcoach/web
mkdir -p /opt/interviewcoach/web/logs
mkdir -p /etc/interviewcoach

chown interviewcoach-api:interviewcoach-api /opt/interviewcoach/api
chown interviewcoach-web:interviewcoach-web /opt/interviewcoach/web
chown interviewcoach-web:interviewcoach-web /opt/interviewcoach/web/logs

echo "=== [7/8] Fichiers d'environnement (à remplir après bootstrap) ==="
cat > /etc/interviewcoach/api.env << 'EOF'
ASPNETCORE_URLS=http://127.0.0.1:5000
ASPNETCORE_ENVIRONMENT=Production
AI_PROVIDER=claude
ANTHROPIC_API_KEY=PLACEHOLDER_REMPLACER_ICI
EOF
chmod 600 /etc/interviewcoach/api.env
chown root:root /etc/interviewcoach/api.env

cat > /etc/interviewcoach/web.env << 'EOF'
NODE_ENV=production
PORT=3000
HOSTNAME=127.0.0.1
EOF
chmod 644 /etc/interviewcoach/web.env
chown root:root /etc/interviewcoach/web.env

echo "=== [8/8] Services systemd et nginx ==="

cat > /etc/systemd/system/interviewcoach-api.service << 'EOF'
[Unit]
Description=InterviewCoach .NET 10 API
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=interviewcoach-api
Group=interviewcoach-api
WorkingDirectory=/opt/interviewcoach/api
ExecStart=/usr/bin/dotnet /opt/interviewcoach/api/InterviewCoach.Api.dll
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=30
EnvironmentFile=/etc/interviewcoach/api.env
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/interviewcoach/api/logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=interviewcoach-api

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/interviewcoach-web.service << 'EOF'
[Unit]
Description=InterviewCoach Next.js Frontend
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=interviewcoach-web
Group=interviewcoach-web
WorkingDirectory=/opt/interviewcoach/web
ExecStart=/usr/bin/node /opt/interviewcoach/web/server.js
Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=30
EnvironmentFile=/etc/interviewcoach/web.env
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/interviewcoach/web/logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=interviewcoach-web

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

cat > /etc/nginx/conf.d/interviewcoach.conf << 'EOF'
upstream api_backend {
    server 127.0.0.1:5000;
    keepalive 32;
}

upstream web_frontend {
    server 127.0.0.1:3000;
    keepalive 16;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/interviewcoach_access.log combined;
    error_log  /var/log/nginx/interviewcoach_error.log warn;

    location ~ ^/(health|alive)$ {
        proxy_pass            http://api_backend;
        proxy_http_version    1.1;
        proxy_set_header      Host              $host;
        proxy_set_header      X-Real-IP         $remote_addr;
        proxy_set_header      X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_read_timeout    10s;
        proxy_connect_timeout 5s;
    }

    # SSE streaming — proxy_buffering off OBLIGATOIRE
    location ~ ^/api/sessions/[^/]+/questions/[^/]+/answer$ {
        proxy_pass            http://api_backend;
        proxy_http_version    1.1;
        proxy_set_header      Connection        "";
        proxy_set_header      Host              $host;
        proxy_set_header      X-Real-IP         $remote_addr;
        proxy_set_header      X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_set_header      X-Fingerprint     $http_x_fingerprint;
        proxy_buffering       off;
        proxy_cache           off;
        proxy_read_timeout    300s;
        proxy_send_timeout    300s;
        proxy_connect_timeout 10s;
        chunked_transfer_encoding on;
        gzip                  off;
        add_header            X-Accel-Buffering no always;
    }

    location /api/ {
        proxy_pass            http://api_backend;
        proxy_http_version    1.1;
        proxy_set_header      Connection        "";
        proxy_set_header      Host              $host;
        proxy_set_header      X-Real-IP         $remote_addr;
        proxy_set_header      X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_set_header      X-Fingerprint     $http_x_fingerprint;
        proxy_read_timeout    60s;
        proxy_connect_timeout 10s;
        proxy_buffering       on;
        proxy_buffer_size     8k;
        proxy_buffers         16 8k;
        client_max_body_size  10m;
    }

    location / {
        proxy_pass            http://web_frontend;
        proxy_http_version    1.1;
        proxy_set_header      Connection        "";
        proxy_set_header      Host              $host;
        proxy_set_header      X-Real-IP         $remote_addr;
        proxy_set_header      X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header      X-Forwarded-Proto $http_x_forwarded_proto;
        proxy_read_timeout    30s;
        proxy_connect_timeout 5s;

        location /_next/static/ {
            proxy_pass         http://web_frontend;
            add_header         Cache-Control "public, max-age=86400, immutable";
        }
    }
}
EOF

nginx -t
systemctl restart nginx

echo "============================================================"
echo "Bootstrap EC2 (sans Amplify) terminé."
echo "PROCHAINES ÉTAPES :"
echo "1. sudo nano /etc/interviewcoach/api.env  → ANTHROPIC_API_KEY"
echo "2. Uploader API  → /opt/interviewcoach/api/"
echo "3. Uploader Web  → /opt/interviewcoach/web/"
echo "4. sudo systemctl enable --now interviewcoach-api interviewcoach-web"
echo "============================================================"
