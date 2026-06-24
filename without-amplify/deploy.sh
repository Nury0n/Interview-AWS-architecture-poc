#!/bin/bash
# ============================================================
# InterviewCoach — Script de déploiement (Solution SANS Amplify)
# Build local + upload SSH vers EC2
#
# Usage :
#   ./deploy.sh api    → déploie l'API .NET uniquement
#   ./deploy.sh web    → déploie le frontend Next.js uniquement
#   ./deploy.sh all    → déploie les deux
#
# Prérequis :
#   - SSH key téléchargée depuis la console AWS EC2
#   - .NET 10 SDK installé localement
#   - Node.js 20+ installé localement
#   - EC2_HOST et SSH_KEY_PATH configurés ci-dessous
# ============================================================
set -euo pipefail

# ── CONFIGURATION ─────────────────────────────────────────────────────────
EC2_HOST="54.X.X.X"                           # Elastic IP EC2 — à remplacer
SSH_KEY_PATH="$HOME/.ssh/interviewcoach-key.pem"
SSH_USER="ec2-user"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ── Couleurs ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Vérifications ─────────────────────────────────────────────────────────
[ -f "$SSH_KEY_PATH" ]        || error "Clé SSH introuvable : $SSH_KEY_PATH"
[ "$EC2_HOST" != "54.X.X.X" ] || error "Configurer EC2_HOST avec l'Elastic IP réelle"
command -v dotnet &>/dev/null  || error ".NET SDK non installé"
command -v node &>/dev/null    || error "Node.js non installé"

ssh_cmd() { ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$EC2_HOST" "$@"; }
scp_cmd() { scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$@"; }

# ── Déploiement API .NET ──────────────────────────────────────────────────
deploy_api() {
    info "=== Déploiement API .NET 10 ==="

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
echo "[EC2] Arrêt du service..."
sudo systemctl stop interviewcoach-api 2>/dev/null || true
echo "[EC2] Déploiement des fichiers..."
sudo rm -rf /opt/interviewcoach/api/*
sudo tar -xzf ~/api.tar.gz -C /opt/interviewcoach/api/
sudo chown -R interviewcoach-api:interviewcoach-api /opt/interviewcoach/api/
echo "[EC2] Démarrage..."
sudo systemctl enable interviewcoach-api
sudo systemctl start interviewcoach-api
sleep 5
echo "[EC2] Health check..."
curl -sf http://127.0.0.1:5000/health && echo " ✓ API OK" || echo " ✗ API KO — vérifier: journalctl -u interviewcoach-api"
rm -f ~/api.tar.gz
REMOTE

    rm -f "$ARCHIVE"
    info "API déployée."
}

# ── Déploiement Frontend Next.js ──────────────────────────────────────────
deploy_web() {
    info "=== Déploiement Frontend Next.js (standalone) ==="

    WEB_SRC="$PROJECT_ROOT/src/web"
    STANDALONE="$WEB_SRC/.next/standalone"
    ARCHIVE="$PROJECT_ROOT/publish/web.tar.gz"
    mkdir -p "$PROJECT_ROOT/publish"

    # Vérifier que NEXT_PUBLIC_API_URL est configurée
    if [ ! -f "$WEB_SRC/.env.production" ]; then
        warn ".env.production absent — NEXT_PUBLIC_API_URL sera vide dans le build"
        warn "Créer src/web/.env.production avec : NEXT_PUBLIC_API_URL=https://XXXX.cloudfront.net"
    fi

    info "npm ci..."
    (cd "$WEB_SRC" && npm ci)

    info "npm run build (Next.js standalone)..."
    (cd "$WEB_SRC" && npm run build)

    # Le bundle standalone n'inclut pas les assets statiques — les copier
    info "Copie des assets statiques dans le bundle..."
    cp -r "$WEB_SRC/.next/static" "$STANDALONE/.next/static"
    [ -d "$WEB_SRC/public" ] && cp -r "$WEB_SRC/public" "$STANDALONE/public" || true

    info "Archivage..."
    tar -czf "$ARCHIVE" -C "$STANDALONE" .

    info "Upload vers EC2 ($EC2_HOST)..."
    scp_cmd "$ARCHIVE" "$SSH_USER@$EC2_HOST:~/web.tar.gz"

    info "Installation sur EC2..."
    ssh_cmd 'bash -s' << 'REMOTE'
set -euo pipefail
echo "[EC2] Arrêt du service..."
sudo systemctl stop interviewcoach-web 2>/dev/null || true
echo "[EC2] Déploiement des fichiers..."
sudo rm -rf /opt/interviewcoach/web/*
sudo tar -xzf ~/web.tar.gz -C /opt/interviewcoach/web/
sudo chown -R interviewcoach-web:interviewcoach-web /opt/interviewcoach/web/
echo "[EC2] Démarrage..."
sudo systemctl enable interviewcoach-web
sudo systemctl start interviewcoach-web
sleep 5
echo "[EC2] Vérification..."
curl -sf -o /dev/null -w "HTTP %{http_code}" http://127.0.0.1:3000 && echo " ✓ Web OK" || echo " ✗ Web KO — vérifier: journalctl -u interviewcoach-web"
rm -f ~/web.tar.gz
REMOTE

    rm -f "$ARCHIVE"
    info "Frontend déployé."
}

# ── Point d'entrée ────────────────────────────────────────────────────────
TARGET="${1:-all}"
case "$TARGET" in
    api)  deploy_api ;;
    web)  deploy_web ;;
    all)  deploy_api && deploy_web ;;
    *)    error "Usage : $0 [api|web|all]" ;;
esac

info "=== Terminé ==="
info "URL : https://XXXX.cloudfront.net"
info "     (remplacer par votre domaine CloudFront)"
