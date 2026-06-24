# Guide de déploiement AWS — Solution SANS Amplify

**Infrastructure :** EC2 (API + Web) + CloudFront | **Déploiement :** Manuel | **Mis à jour :** 2026-06-24

> Pour la solution avec Amplify, voir `../with-amplify/`  
> Pour le comparatif des deux solutions, voir `../README.md`

---

## Table des matières

1. [Architecture](#1-architecture)
2. [Prérequis](#2-prérequis)
3. [Étape 1 — Lancer l'instance EC2](#3-étape-1--lancer-linstance-ec2)
4. [Étape 2 — Configurer CloudFront](#4-étape-2--configurer-cloudfront)
5. [Étape 3 — Déployer l'application](#5-étape-3--déployer-lapplication)
6. [Étape 4 — Vérification et tests](#6-étape-4--vérification-et-tests)
7. [Opérations courantes](#7-opérations-courantes)
8. [Limites Free Tier](#8-limites-free-tier)
9. [Dépannage](#9-dépannage)

---

## 1. Architecture

```
Internet
    │
    └── CloudFront (HTTPS)           ← certificat SSL géré par AWS
              │  HTTP :80
              ▼
         EC2 t2.micro (Amazon Linux 2023)
         Elastic IP fixe
         nginx :80 (reverse proxy)
           ├── /api/*   →  .NET API   :5000  (systemd)
           ├── /health  →  .NET API   :5000
           └── /*       →  Next.js    :3000  (systemd)
```

**Flux SSE (streaming feedback IA) :**
```
Browser → CloudFront → nginx (buffering=off) → Kestrel :5000
  ◄─────────────── event:token (chunk par chunk) ──────────────
  ◄─────────────── event:result ───────────────────────────────
  ◄─────────────── event:done ─────────────────────────────────
```

**Choix de cette architecture :**

| Contrainte | Raison |
|-----------|--------|
| Sessions en RAM | EC2 long-running — Lambda effacerait la mémoire entre invocations |
| SSE streaming | `proxy_buffering off` nginx + CloudFront Compress=No |
| Next.js SSR | `output: "standalone"` → `server.js` Node.js autonome, pas besoin d'Amplify |
| HTTPS | CloudFront gère le cert SSL — EC2 reste en HTTP interne |
| Secrets IA | `/etc/interviewcoach/api.env` chmod 600, jamais dans le JS frontend |

**Coût Free Tier (12 premiers mois) :**

| Service | Limite gratuite | Coût post-12 mois |
|---------|----------------|-------------------|
| EC2 t2.micro | 750 h/mois | ~$8.5/mois |
| EBS 20 GB gp3 | 30 GB inclus | ~$1.6/mois |
| Elastic IP | Gratuit si instance active | $0.005/h si non associée |
| CloudFront | 1 TB + 10 M req/mois | ~$0.0085/GB |

---

## 2. Prérequis

**Sur votre machine locale :**
- [ ] [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10)
- [ ] [Node.js 20+](https://nodejs.org/)
- [ ] [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [ ] Un compte AWS

**Dans la console AWS — à faire avant de commencer :**

**1. Créer une Key Pair :**
Console EC2 → Key Pairs → Create key pair
```
Nom    : interviewcoach-key
Format : .pem
```
Télécharger et sécuriser :
```bash
mv ~/Downloads/interviewcoach-key.pem ~/.ssh/
chmod 400 ~/.ssh/interviewcoach-key.pem
```

**2. Créer un Security Group :**
Console EC2 → Security Groups → Create security group

| Direction | Type | Port | Source | Pourquoi |
|-----------|------|------|--------|----------|
| Entrante | SSH | 22 | Votre IP/32 | Admin — JAMAIS 0.0.0.0/0 |
| Entrante | HTTP | 80 | 0.0.0.0/0 | CloudFront → nginx |
| Sortante | HTTPS | 443 | 0.0.0.0/0 | API IA (Anthropic, etc.) |
| Sortante | HTTP | 80 | 0.0.0.0/0 | Mises à jour dnf |
| Sortante | DNS | 53 | 0.0.0.0/0 | Résolution DNS |

---

## 3. Étape 1 — Lancer l'instance EC2

### 3.1 Lancer l'instance

Console EC2 → Launch Instance :

```
Nom            : interviewcoach-prod
AMI            : Amazon Linux 2023 AMI (64-bit x86)
Instance type  : t2.micro                    ← FREE TIER
Key pair       : interviewcoach-key
Security group : (celui créé ci-dessus)
Storage        : 20 GB gp3
```

**User Data** (onglet "Advanced details → User data") :
→ Coller le contenu intégral du fichier `user-data.sh`

Cliquer **Launch Instance** et attendre 3-5 minutes.

### 3.2 Associer une Elastic IP

Console EC2 → Elastic IPs → Allocate Elastic IP address → Allocate

Puis : Actions → Associate Elastic IP address → sélectionner l'instance

> Noter cette IP — c'est l'adresse permanente du serveur.

### 3.3 Vérifier le bootstrap

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<ELASTIC-IP>

# Vérifier que le bootstrap s'est terminé sans erreur
sudo tail -50 /var/log/user-data.log
# La dernière ligne doit être : "Bootstrap EC2 (sans Amplify) terminé."

# Vérifier nginx
sudo systemctl status nginx
```

### 3.4 Configurer les secrets API

```bash
# Sur EC2 :
sudo nano /etc/interviewcoach/api.env

# Remplacer PLACEHOLDER_REMPLACER_ICI :
ANTHROPIC_API_KEY=sk-ant-api03-votre-vraie-cle-ici

# Sauvegarder : Ctrl+O, Entrée, Ctrl+X
```

---

## 4. Étape 2 — Configurer CloudFront

### 4.1 Créer la distribution

Console → CloudFront → Create distribution

**Origin settings :**
```
Origin domain      : <ELASTIC-IP>   (ex: 54.123.45.67 — IP directe, pas de DNS)
Protocol           : HTTP only       ← EC2 sans cert SSL, CloudFront gère le HTTPS
HTTP port          : 80
Name               : interviewcoach-ec2
Response timeout   : 60 secondes
```

**Default cache behavior :**
```
Viewer protocol policy : Redirect HTTP to HTTPS
Allowed HTTP methods   : GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE
Cache policy           : CachingDisabled
Origin request policy  : AllViewer
Compress objects       : No          ← CRITIQUE — la compression bufférise le SSE
```

**Settings :**
```
Price class : Use only North America and Europe
Comment     : InterviewCoach
```

→ Cliquer **Create distribution** (propagation : 10-20 min)

### 4.2 Récupérer et noter le domaine

Une fois déployée : `XXXXXXXXXXXXX.cloudfront.net` → noter cette URL.

### 4.3 Vérifier CloudFront → EC2

```bash
# Doit retourner 502 (service pas encore démarré) mais confirme la connectivité
curl -I https://XXXXXXXXXXXXX.cloudfront.net/health
```

---

## 5. Étape 3 — Déployer l'application

### 5.1 Configurer le script de déploiement

Éditer `deploy.sh`, remplacer les deux premières variables :
```bash
EC2_HOST="54.X.X.X"                           # → votre Elastic IP réelle
SSH_KEY_PATH="$HOME/.ssh/interviewcoach-key.pem"
```

### 5.2 Configurer NEXT_PUBLIC_API_URL

Cette variable est **gravée dans le bundle JS au moment du `npm run build`**. Elle doit pointer vers CloudFront avant le build.

Créer `src/web/.env.production` à la racine du projet :
```
NEXT_PUBLIC_API_URL=https://XXXXXXXXXXXXX.cloudfront.net
```

> Ce fichier contient une URL publique (pas un secret) — il peut être commité.

### 5.3 Lancer le déploiement complet

```bash
# Depuis la racine du projet
chmod +x deploy/without-amplify/deploy.sh
./deploy/without-amplify/deploy.sh all
```

Le script fait automatiquement :
1. `dotnet publish` → binaire Linux x64
2. `npm ci && npm run build` → bundle standalone Next.js
3. Copie des assets statiques dans le bundle
4. `scp` de l'archive vers EC2
5. Arrêt / déploiement / démarrage des services systemd
6. Vérification health checks

---

## 6. Étape 4 — Vérification et tests

### 6.1 Vérifications de base

```bash
CF="https://XXXXXXXXXXXXX.cloudfront.net"

# Health checks API
curl -s $CF/health    # → {"status":"Healthy"}
curl -s $CF/alive     # → {"status":"Healthy"}

# Frontend accessible
curl -sI $CF          # → HTTP/2 200

# Statut des services
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<EC2-IP> \
    "sudo systemctl status interviewcoach-api interviewcoach-web --no-pager"
```

### 6.2 Test du SSE streaming

```bash
CF="https://XXXXXXXXXXXXX.cloudfront.net"

# Créer une session (avec un vrai PDF de CV)
SESSION=$(curl -s -X POST $CF/api/sessions \
  -H "X-Fingerprint: test-validation-$(date +%s)" \
  -F "cvFile=@tests/InterviewCoach.E2E.Tests/test-cv.pdf" \
  -F "jobOfferText=Poste développeur backend .NET senior")

SESSION_ID=$(echo $SESSION | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionId'])")
echo "Session : $SESSION_ID"

# Générer les questions
QUESTIONS=$(curl -s -X POST $CF/api/sessions/$SESSION_ID/questions)
QUESTION_ID=$(echo $QUESTIONS | python3 -c "import sys,json; print(json.load(sys.stdin)['questions'][0]['id'])")

# Tester le streaming SSE — on doit voir les tokens défiler
curl -N -X POST $CF/api/sessions/$SESSION_ID/questions/$QUESTION_ID/answer \
  -H "Content-Type: application/json" \
  -d '{"text":"Je suis passionné par le développement backend et les architectures distribuées."}'
# Sortie attendue : event:token, event:token, ..., event:result, event:done
```

---

## 7. Opérations courantes

### Redéployer après un changement

```bash
./deploy/without-amplify/deploy.sh api    # API uniquement
./deploy/without-amplify/deploy.sh web    # Frontend uniquement
./deploy/without-amplify/deploy.sh all    # Les deux
```

### Changer la clé API IA

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<EC2-IP>
sudo nano /etc/interviewcoach/api.env     # Modifier ANTHROPIC_API_KEY
sudo systemctl restart interviewcoach-api
```

### Consulter les logs

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<EC2-IP>

sudo journalctl -u interviewcoach-api -f           # Logs API en temps réel
sudo journalctl -u interviewcoach-web -f           # Logs Next.js en temps réel
sudo tail -f /var/log/nginx/interviewcoach_access.log  # Logs accès nginx
sudo tail -f /var/log/nginx/interviewcoach_error.log   # Logs erreurs nginx
```

### Arrêter l'instance EC2 (économie free tier)

Console EC2 → Instance State → Stop.

> L'Elastic IP reste associée même instance arrêtée → reste gratuite.  
> Les sessions en mémoire sont perdues (by design — prototype).

---

## 8. Limites Free Tier

| Ressource | Limite | Statut |
|-----------|--------|--------|
| EC2 t2.micro | 750 h/mois = 24/7 | ✓ OK avec 1 instance |
| EBS 20 GB gp3 | 30 GB inclus | ✓ OK |
| Elastic IP | Gratuit si instance active | ⚠ Coûte si non associée |
| CloudFront | 1 TB + 10 M req | ✓ OK pour un proto |

**Après 12 mois :** ~$12-15/mois si instance toujours running.

**Piège :** Elastic IP non associée = $0.005/h ≈ $3.6/mois. Toujours associer ou libérer.

---

## 9. Dépannage

### API retourne 502

```bash
ssh ... "sudo systemctl status interviewcoach-api"
ssh ... "sudo journalctl -u interviewcoach-api --since '5 min ago'"
ssh ... "curl -s http://127.0.0.1:5000/health"   # Test direct hors nginx
```
Cause fréquente : `ANTHROPIC_API_KEY` absente ou invalide dans `/etc/interviewcoach/api.env`.

### SSE ne stream pas (feedback arrive d'un coup)

```bash
ssh ... "grep -A2 'answer\$' /etc/nginx/conf.d/interviewcoach.conf | grep buffering"
# Doit afficher : proxy_buffering off;
```
Et dans CloudFront : Default behavior → Compress = No.

### 504 Gateway Timeout sur le feedback

CloudFront timeout max = 60s. Si Claude dépasse → 504.  
Solution : utiliser `claude-haiku` ou `claude-sonnet` (plus rapides).

### Frontend affiche "Erreur réseau" sur les appels API

`NEXT_PUBLIC_API_URL` est mauvaise dans le bundle.  
Corriger `src/web/.env.production`, puis `./deploy.sh web`.

### EC2 ne répond plus (RAM pleine)

```bash
ssh ... "free -h"
ssh ... "sudo journalctl -u interviewcoach-api --since '1 hour ago' | grep -i oom"
```
.NET + Node.js + nginx = ~720 MB. Le swap 1 GB (user-data) protège les OOM kills.
