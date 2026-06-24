#!/bin/bash
# ============================================================
# InterviewCoach — EC2 Bootstrap (Solution AVEC Amplify)
# EC2 héberge UNIQUEMENT : API .NET + nginx
# Le frontend Next.js est hébergé par AWS Amplify
#
# À coller dans "Advanced Details → User data" lors du lancement EC2
# S'exécute UNE SEULE FOIS au premier démarrage
# Log : /var/log/user-data.log
# ============================================================
set -euxo pipefail
exec > /var/log/user-data.log 2>&1

echo "=== [1/6] Mise à jour système ==="
dnf update -y

echo "=== [2/6] Swap 1 GB (compensation RAM t2.micro 1 GB) ==="
fallocate -l 1G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo "=== [3/6] Installation .NET 10 runtime ==="
dnf install -y dotnet-runtime-10.0
dotnet --version

echo "=== [4/6] Installation nginx ==="
dnf install -y nginx
systemctl enable nginx

echo "=== [5/6] Utilisateur système et répertoires ==="
useradd --system --no-create-home --shell /bin/false interviewcoach-api || true
mkdir -p /opt/interviewcoach/api
mkdir -p /etc/interviewcoach
chown interviewcoach-api:interviewcoach-api /opt/interviewcoach/api

echo "=== [6/6] Fichier d'environnement, service systemd et nginx ==="
cat > /etc/interviewcoach/api.env << 'EOF'
ASPNETCORE_URLS=http://127.0.0.1:5000
ASPNETCORE_ENVIRONMENT=Production
AI_PROVIDER=claude
ANTHROPIC_API_KEY=PLACEHOLDER_REMPLACER_ICI
EOF
chmod 600 /etc/interviewcoach/api.env
chown root:root /etc/interviewcoach/api.env

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

systemctl daemon-reload

# nginx : uniquement l'API (pas de frontend, Amplify s'en charge)
cat > /etc/nginx/conf.d/interviewcoach.conf << 'EOF'
upstream api_backend {
    server 127.0.0.1:5000;
    keepalive 32;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/interviewcoach_access.log combined;
    error_log  /var/log/nginx/interviewcoach_error.log warn;

    # Health checks
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

    # API .NET
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

    # Bloquer tout ce qui n'est pas l'API
    location / {
        return 404;
    }
}
EOF

nginx -t
systemctl restart nginx

echo "============================================================"
echo "Bootstrap EC2 (avec Amplify) terminé."
echo "PROCHAINES ÉTAPES :"
echo "1. sudo nano /etc/interviewcoach/api.env  → ANTHROPIC_API_KEY"
echo "2. Uploader l'API → /opt/interviewcoach/api/"
echo "3. sudo systemctl enable --now interviewcoach-api"
echo "4. Créer la distribution CloudFront (origin = cette IP)"
echo "5. Créer l'app Amplify avec NEXT_PUBLIC_API_URL = URL CloudFront"
echo "============================================================"
