#!/bin/bash
# ============================================================
# InterviewCoach — Déploiement API (Solution AVEC Amplify)
# Ne déploie QUE l'API .NET — le frontend est géré par Amplify
#
# Usage : ./deploy-api.sh
# ============================================================
set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────
EC2_HOST="54.X.X.X"                           # Elastic IP EC2 — à remplacer
SSH_KEY_PATH="$HOME/.ssh/interviewcoach-key.pem"
SSH_USER="ec2-user"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ -f "$SSH_KEY_PATH" ]        || error "Clé SSH introuvable : $SSH_KEY_PATH"
[ "$EC2_HOST" != "54.X.X.X" ] || error "Configurer EC2_HOST"
command -v dotnet &>/dev/null  || error ".NET SDK non installé"

ssh_cmd() { ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$EC2_HOST" "$@"; }
scp_cmd() { scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$@"; }

info "=== Déploiement API .NET 10 (solution avec Amplify) ==="

BUILD_OUT="$PROJECT_ROOT/publish/api"
ARCHIVE="$PROJECT_ROOT/publish/api.tar.gz"
mkdir -p "$PROJECT_ROOT/publish"

info "dotnet publish (Release, linux-x64)..."
dotnet publish "$PROJECT_ROOT/src/api/InterviewCoach.Api.csproj" \
    --configuration Release \
    --runtime linux-x64 \
    --self-contained false \
    --output "$BUILD_OUT"

info "Archivage..."
tar -czf "$ARCHIVE" -C "$BUILD_OUT" .

info "Upload vers EC2 ($EC2_HOST)..."
scp_cmd "$ARCHIVE" "$SSH_USER@$EC2_HOST:~/api.tar.gz"

info "Installation sur EC2..."
ssh_cmd 'bash -s' << 'REMOTE'
set -euo pipefail
sudo systemctl stop interviewcoach-api 2>/dev/null || true
sudo rm -rf /opt/interviewcoach/api/*
sudo tar -xzf ~/api.tar.gz -C /opt/interviewcoach/api/
sudo chown -R interviewcoach-api:interviewcoach-api /opt/interviewcoach/api/
sudo systemctl enable interviewcoach-api
sudo systemctl start interviewcoach-api
sleep 5
curl -sf http://127.0.0.1:5000/health && echo " ✓ API OK" || echo " ✗ API KO"
rm -f ~/api.tar.gz
REMOTE

rm -f "$ARCHIVE"
info "API déployée. Le frontend Next.js est géré par Amplify."
info "Pour redéployer le frontend : déclencher un build dans la console Amplify."
