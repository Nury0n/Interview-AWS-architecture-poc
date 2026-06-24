# Guide de déploiement AWS — Solution AVEC Amplify

**Infrastructure :** EC2 (API) + CloudFront + Amplify (Web) | **Déploiement :** Manuel | **Mis à jour :** 2026-06-24

> Pour la solution sans Amplify (tout sur EC2), voir `../without-amplify/`  
> Pour le comparatif des deux solutions, voir `../README.md`

---

## Table des matières

1. [Architecture](#1-architecture)
2. [Prérequis](#2-prérequis)
3. [Étape 1 — Lancer l'instance EC2](#3-étape-1--lancer-linstance-ec2)
4. [Étape 2 — Configurer CloudFront](#4-étape-2--configurer-cloudfront)
5. [Étape 3 — Déployer l'API](#5-étape-3--déployer-lapi)
6. [Étape 4 — Configurer et déployer Amplify](#6-étape-4--configurer-et-déployer-amplify)
7. [Étape 5 — Vérification et tests](#7-étape-5--vérification-et-tests)
8. [Opérations courantes](#8-opérations-courantes)
9. [Limites Free Tier](#9-limites-free-tier)
10. [Dépannage](#10-dépannage)

---

## 1. Architecture

```
Internet
    │
    ├── AWS Amplify (HTTPS)       ← Frontend Next.js SSR
    │   https://main.XXXX.amplifyapp.com
    │   NEXT_PUBLIC_API_URL ────────────────────────┐
    │                                                ▼
    └── CloudFront (HTTPS)        ← API uniquement
        https://XXXX.cloudfront.net
              │  HTTP :80
              ▼
         EC2 t2.micro (Amazon Linux 2023)
         Elastic IP fixe
         nginx :80
           ├── /api/*   →  .NET API   :5000
           └── /health  →  .NET API   :5000
```

**Flux SSE :**
```
Browser → Amplify (rendu SSR) → [fetch côté client] → CloudFront → nginx → Kestrel
  ◄──────────────────────── event:token (chunk) ────────────────────────────────
```

**Points critiques de cette architecture :**

| Point | Détail |
|-------|--------|
| `NEXT_PUBLIC_API_URL` | Inlinée dans le bundle JS **au build Amplify** → doit pointer vers CloudFront avant le build |
| SSE + CloudFront | Behavior SSE doit avoir **Compress = No** sinon les tokens arrivent d'un coup |
| SSE + CloudFront | Timeout max CloudFront = 60s — utiliser claude-haiku ou claude-sonnet |
| Secrets IA | Uniquement dans `/etc/interviewcoach/api.env` sur EC2, jamais dans les variables Amplify |
| CORS | L'API accepte tous les origines — en prod, restreindre à l'URL Amplify dans nginx |

**Coût Free Tier (12 premiers mois) :**

| Service | Limite gratuite | Coût post-12 mois |
|---------|----------------|-------------------|
| EC2 t2.micro | 750 h/mois | ~$8.5/mois |
| EBS 20 GB gp3 | 30 GB inclus | ~$1.6/mois |
| Elastic IP | Gratuit si instance active | $0.005/h si non associée |
| CloudFront | 1 TB + 10 M req/mois | ~$0.0085/GB |
| Amplify Build | 1 000 min/mois | $0.01/min |
| Amplify Hosting | 5 GB + 15 GB data out | ~$0.15/GB |

---

## 2. Prérequis

**Sur votre machine locale :**
- [ ] [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10)
- [ ] [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [ ] Un compte AWS
- [ ] Code source disponible (local ou repo Git)

> Contrairement à la solution sans Amplify, Node.js n'est **pas nécessaire localement** — Amplify fait le build dans le cloud.

**Dans la console AWS :**

**1. Key Pair SSH :**
Console EC2 → Key Pairs → Create key pair
```
Nom    : interviewcoach-key
Format : .pem
```
```bash
mv ~/Downloads/interviewcoach-key.pem ~/.ssh/
chmod 400 ~/.ssh/interviewcoach-key.pem
```

**2. Security Group :**

| Direction | Type | Port | Source |
|-----------|------|------|--------|
| Entrante | SSH | 22 | Votre IP/32 |
| Entrante | HTTP | 80 | 0.0.0.0/0 |
| Sortante | HTTPS | 443 | 0.0.0.0/0 |
| Sortante | HTTP | 80 | 0.0.0.0/0 |
| Sortante | DNS | 53 | 0.0.0.0/0 |

---

## 3. Étape 1 — Lancer l'instance EC2

### 3.1 Lancer l'instance

Console EC2 → Launch Instance :
```
Nom            : interviewcoach-api
AMI            : Amazon Linux 2023 AMI (64-bit x86)
Instance type  : t2.micro       ← FREE TIER
Key pair       : interviewcoach-key
Security group : (celui créé ci-dessus)
Storage        : 20 GB gp3
```

**User Data** → coller le contenu de `user-data.sh` (version avec Amplify — n'installe pas Node.js).

### 3.2 Associer une Elastic IP

EC2 → Elastic IPs → Allocate → Associate → sélectionner l'instance.

### 3.3 Vérifier le bootstrap

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<ELASTIC-IP>
sudo tail -30 /var/log/user-data.log
# Dernière ligne : "Bootstrap EC2 (avec Amplify) terminé."
```

### 3.4 Configurer les secrets

```bash
sudo nano /etc/interviewcoach/api.env
# Remplacer PLACEHOLDER_REMPLACER_ICI par la vraie clé Anthropic
```

---

## 4. Étape 2 — Configurer CloudFront

Console → CloudFront → Create distribution

**Origin settings :**
```
Origin domain  : <ELASTIC-IP>
Protocol       : HTTP only
HTTP port      : 80
Response timeout : 60 secondes
```

**Default cache behavior :**
```
Viewer protocol policy : Redirect HTTP to HTTPS
Allowed HTTP methods   : GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE
Cache policy           : CachingDisabled
Origin request policy  : AllViewer
Compress objects       : No     ← CRITIQUE pour le SSE
```

> Cliquer **Create distribution** — noter le domaine `XXXXXXXXXXXXX.cloudfront.net` (propagation 10-20 min).

---

## 5. Étape 3 — Déployer l'API

### 5.1 Configurer le script

Éditer `deploy-api.sh` :
```bash
EC2_HOST="54.X.X.X"                           # → votre Elastic IP
SSH_KEY_PATH="$HOME/.ssh/interviewcoach-key.pem"
```

### 5.2 Lancer le déploiement

```bash
chmod +x deploy/with-amplify/deploy-api.sh
./deploy/with-amplify/deploy-api.sh
```

### 5.3 Vérifier

```bash
CF="https://XXXXXXXXXXXXX.cloudfront.net"
curl -s $CF/health    # → {"status":"Healthy"}
curl -s $CF/alive     # → {"status":"Healthy"}
```

---

## 6. Étape 4 — Configurer et déployer Amplify

### 6.1 Copier amplify.yml à la racine du projet

```bash
cp deploy/with-amplify/amplify.yml ./amplify.yml
```

Ce fichier dit à Amplify comment builder le frontend Next.js depuis `src/web/`.

### 6.2 Créer l'application Amplify

Console → AWS Amplify → Create new app → Host your web app

**Option A — Deploy without Git (déploiement manuel) :**
1. Choisir "Deploy without Git provider"
2. Méthode : "Drag and drop" ou AWS CLI upload
3. Configurer les variables d'environnement avant le premier build

**Option B — Connecter un repo Git (semi-automatique) :**
1. GitHub / GitLab / Bitbucket → sélectionner le repo
2. Branch : `main` (ou la vôtre)
3. Désactiver "Auto-build on push" si vous préférez le déploiement manuel

### 6.3 Configurer les variables d'environnement Amplify

Console Amplify → App settings → Environment variables → Manage variables

| Variable | Valeur | Important |
|----------|--------|-----------|
| `NEXT_PUBLIC_API_URL` | `https://XXXXXXXXXXXXX.cloudfront.net` | Inlinée au build — pointer vers CloudFront |

> **NE PAS ajouter dans Amplify :**
> - `ANTHROPIC_API_KEY` — visible en clair dans la console, doit rester sur EC2 uniquement
> - Toute clé d'API IA

### 6.4 Paramètre Platform

Console Amplify → App settings → General → Edit

```
Platform : Web Compute    ← OBLIGATOIRE pour Next.js SSR
           (PAS "Web" qui est pour les apps statiques)
```

### 6.5 Déclencher le premier build

Console Amplify → Run build

Le build prend ~3-5 minutes. Récupérer l'URL : `https://main.XXXXXXXX.amplifyapp.com`

### 6.6 (Optionnel) Restreindre le CORS

L'API accepte actuellement tous les origines. Pour restreindre à l'URL Amplify :

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<EC2-IP>
sudo nano /etc/nginx/conf.d/interviewcoach.conf
```

Ajouter dans le bloc `location /api/` :
```nginx
add_header 'Access-Control-Allow-Origin'  'https://main.XXXXXXXX.amplifyapp.com' always;
add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
add_header 'Access-Control-Allow-Headers' 'Content-Type, X-Fingerprint' always;

if ($request_method = OPTIONS) {
    return 204;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 7. Étape 5 — Vérification et tests

```bash
CF="https://XXXXXXXXXXXXX.cloudfront.net"
AMPLIFY="https://main.XXXXXXXX.amplifyapp.com"

# API via CloudFront
curl -s $CF/health                    # → {"status":"Healthy"}

# Frontend Amplify
curl -sI $AMPLIFY                     # → HTTP/2 200

# Test SSE streaming
SESSION=$(curl -s -X POST $CF/api/sessions \
  -H "X-Fingerprint: test-$(date +%s)" \
  -F "cvFile=@tests/InterviewCoach.E2E.Tests/test-cv.pdf" \
  -F "jobOfferText=Poste développeur .NET senior")
SESSION_ID=$(echo $SESSION | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionId'])")

QUESTIONS=$(curl -s -X POST $CF/api/sessions/$SESSION_ID/questions)
QUESTION_ID=$(echo $QUESTIONS | python3 -c "import sys,json; print(json.load(sys.stdin)['questions'][0]['id'])")

# Les tokens IA doivent défiler en temps réel
curl -N -X POST $CF/api/sessions/$SESSION_ID/questions/$QUESTION_ID/answer \
  -H "Content-Type: application/json" \
  -d '{"text":"Je maîtrise les architectures microservices et les patterns DDD."}'
```

---

## 8. Opérations courantes

### Redéployer l'API

```bash
./deploy/with-amplify/deploy-api.sh
```

### Redéployer le frontend

Console Amplify → Run build  
(ou `amplify publish` si CLI configuré)

### Changer la clé API IA

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<EC2-IP>
sudo nano /etc/interviewcoach/api.env
sudo systemctl restart interviewcoach-api
```

### Voir les logs API

```bash
ssh -i ~/.ssh/interviewcoach-key.pem ec2-user@<EC2-IP>
sudo journalctl -u interviewcoach-api -f
sudo tail -f /var/log/nginx/interviewcoach_error.log
```

### Voir les logs Amplify

Console Amplify → Deployments → Build logs

---

## 9. Limites Free Tier

| Ressource | Limite | Notes |
|-----------|--------|-------|
| EC2 t2.micro | 750 h/mois | 1 instance 24/7 = 744h ✓ |
| EBS 20 GB | 30 GB inclus | ✓ |
| Elastic IP | Gratuit si active | ⚠ Coûte si non associée |
| CloudFront | 1 TB + 10 M req | ✓ proto |
| Amplify Build | 1 000 min/mois | ~5 min/build → 200 builds max |
| Amplify Hosting | 5 GB stockage + 15 GB out | ✓ proto |

**Piège Amplify :** si vous déclenchez des builds fréquemment (CI/CD actif), les 1 000 min peuvent être consommées rapidement. En déploiement manuel, un build ≈ 5 min → 200 déploiements/mois maximum.

---

## 10. Dépannage

### API retourne 502

```bash
ssh ... "sudo systemctl status interviewcoach-api"
ssh ... "sudo journalctl -u interviewcoach-api --since '5 min ago'"
ssh ... "curl -s http://127.0.0.1:5000/health"
```
Cause fréquente : `ANTHROPIC_API_KEY` manquante dans `/etc/interviewcoach/api.env`.

### SSE ne stream pas (feedback arrive d'un coup)

1. nginx : `proxy_buffering off` dans le bloc SSE → vérifier avec `grep buffering /etc/nginx/conf.d/interviewcoach.conf`
2. CloudFront : Default behavior → Compress = No

### 504 sur le feedback IA

CloudFront timeout = 60s max. Utiliser `claude-haiku` ou `claude-sonnet`.

### Build Amplify échoue

Console Amplify → Deployments → Build logs → chercher l'erreur.

Causes fréquentes :
- `amplify.yml` absent à la racine du repo
- Platform définie sur "Web" au lieu de "Web Compute"
- `NEXT_PUBLIC_API_URL` non définie → le build réussit mais l'app ne peut pas appeler l'API

### Frontend affiche "Erreur réseau"

`NEXT_PUBLIC_API_URL` est incorrecte dans les variables Amplify.  
Corriger la variable → relancer un build → redéployer.

### Erreur CORS sur les appels API

Le navigateur bloque les requêtes cross-origin.  
Vérifier que l'URL Amplify est bien dans `Access-Control-Allow-Origin` dans nginx,  
ou que `SetIsOriginAllowed(_ => true)` est bien actif dans `Program.cs`.
