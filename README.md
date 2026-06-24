# Déploiement AWS — InterviewCoach

Deux solutions disponibles, toutes deux gratuites (AWS Free Tier) :

```
deploy/
├── README.md                   ← CE FICHIER — comparatif et choix
│
├── without-amplify/            ← SOLUTION A : tout sur une seule EC2
│   ├── user-data.sh            Bootstrap EC2 (.NET + Node.js + nginx)
│   ├── interviewcoach-api.service  systemd API .NET
│   ├── interviewcoach-web.service  systemd Next.js
│   ├── nginx.conf              Reverse proxy API + Web
│   ├── deploy.sh               Script de déploiement (api / web / all)
│   ├── api.env.example         Template secrets API
│   ├── web.env.example         Template env Next.js
│   └── DEPLOY.md               Guide pas-à-pas complet
│
└── with-amplify/               ← SOLUTION B : EC2 (API) + Amplify (Web)
    ├── user-data.sh            Bootstrap EC2 (.NET + nginx uniquement)
    ├── interviewcoach-api.service  systemd API .NET
    ├── nginx-api-only.conf     Reverse proxy API uniquement
    ├── amplify.yml             Configuration build Amplify (à copier à la racine du repo)
    ├── deploy-api.sh           Script de déploiement API uniquement
    ├── api.env.example         Template secrets API
    └── DEPLOY.md               Guide pas-à-pas complet
```

---

## Comparatif des deux solutions

| Critère | Solution A — Sans Amplify | Solution B — Avec Amplify |
|---------|--------------------------|--------------------------|
| **Services AWS** | EC2 + CloudFront | EC2 + CloudFront + Amplify |
| **Complexité** | ⭐ Plus simple | ⭐⭐ Plus complexe |
| **EC2 héberge** | API .NET + Next.js + nginx | API .NET + nginx uniquement |
| **RAM EC2 utilisée** | ~720 MB (juste) | ~400 MB (confortable) |
| **Déploiement frontend** | `./deploy.sh web` (SSH) | Build dans la console Amplify |
| **NEXT_PUBLIC_API_URL** | Dans `src/web/.env.production` | Dans les variables Amplify |
| **Limite build Amplify** | N/A | 1 000 min/mois (free tier) |
| **SSE streaming** | nginx `proxy_buffering off` | nginx + CloudFront Compress=No |
| **HTTPS** | CloudFront → EC2 HTTP | CloudFront → EC2 HTTP + Amplify HTTPS natif |
| **Coût post-12 mois** | ~$12/mois | ~$13/mois (+Amplify ~$1) |
| **Séparation des responsabilités** | Tout sur un seul serveur | API et Web clairement séparés |

### Quand choisir la Solution A (sans Amplify)

- Vous voulez **la simplicité maximale** — un seul serveur, tout au même endroit
- Vous déployez manuellement et ne voulez pas gérer Amplify
- Le proto a peu de trafic simultané (contrainte RAM 1 GB)
- Vous êtes à l'aise avec SSH et systemd

### Quand choisir la Solution B (avec Amplify)

- Vous voulez **séparer clairement** le frontend du backend
- Vous souhaitez un **historique de builds** et une interface graphique pour les déploiements
- Vous prévoyez de connecter un repo Git pour des déploiements semi-automatiques plus tard
- La RAM de l'EC2 est une préoccupation (Amplify soulage l'EC2 de ~150 MB)

---

## Architecture — Solution A (Sans Amplify)

```
Internet
    │
    └── CloudFront (HTTPS)
              │  HTTP :80
              ▼
         EC2 t2.micro
         nginx :80
           ├── /api/*   →  .NET API   :5000
           ├── /health  →  .NET API   :5000
           └── /*       →  Next.js    :3000
```

**Flux SSE :**
```
Browser → CloudFront → nginx (buffering=off) → Kestrel :5000
  ◄─────────────── event:token (chunk par chunk) ──────────────
```

→ **Guide complet :** `without-amplify/DEPLOY.md`

---

## Architecture — Solution B (Avec Amplify)

```
Internet
    │
    ├── Amplify (HTTPS)       ← Frontend Next.js SSR
    │   NEXT_PUBLIC_API_URL ──────────────────────┐
    │                                              ▼
    └── CloudFront (HTTPS)    ← API uniquement
              │  HTTP :80
              ▼
         EC2 t2.micro
         nginx :80
           ├── /api/*   →  .NET API   :5000
           └── /health  →  .NET API   :5000
```

**Points d'attention spécifiques à la Solution B :**

1. **NEXT_PUBLIC_API_URL** doit être définie dans Amplify → App settings → Environment variables **avant** de déclencher le build. Elle est inlinée dans le bundle JS.

2. **CORS** : l'API autorise tous les origines (`SetIsOriginAllowed(_ => true)`). En production, restreindre dans `nginx-api-only.conf` à l'URL Amplify exacte.

3. **SSE + CloudFront** : le behavior `/api/sessions/*/questions/*/answer` doit avoir **Compress = No** dans CloudFront. Sans ça, CloudFront bufférise toute la réponse avant de la compresser et le streaming est brisé.

4. **Timeout CloudFront = 60s max** : si Claude prend plus de 60s, le client reçoit un 504. Utiliser `claude-haiku` ou `claude-sonnet` (plus rapides).

→ **Guide complet :** `with-amplify/DEPLOY.md`

---

## Ordre de déploiement (commun aux deux solutions)

```
1. Créer la Key Pair SSH dans la console EC2
2. Créer le Security Group (port 22 votre IP, port 80 ouvert)
3. Lancer l'instance EC2 (t2.micro, Amazon Linux 2023, user-data.sh)
4. Associer une Elastic IP à l'instance
5. Configurer /etc/interviewcoach/api.env (ANTHROPIC_API_KEY)
6. Déployer l'API .NET
7. Créer la distribution CloudFront (origin = Elastic IP, HTTP)

── Solution A uniquement ──────────────────────────────────────
8. Créer src/web/.env.production avec NEXT_PUBLIC_API_URL
   Déployer le frontend : ./without-amplify/deploy.sh web

── Solution B uniquement ──────────────────────────────────────
8. Créer l'app Amplify (Framework: Next.js SSR / Web Compute)
   Définir NEXT_PUBLIC_API_URL = https://XXXX.cloudfront.net
   Copier amplify.yml à la racine du repo
   Déclencher le build

9. Vérifier : curl https://XXXX.cloudfront.net/health
```

---

## Checklist de mise en production

- [ ] Clé SSH téléchargée et `chmod 400`
- [ ] Security Group : port 22 restreint à votre IP
- [ ] `/etc/interviewcoach/api.env` : `ANTHROPIC_API_KEY` remplacée, `chmod 600`
- [ ] EC2 : health check OK — `curl http://127.0.0.1:5000/health`
- [ ] nginx : config validée — `sudo nginx -t`
- [ ] CloudFront : distribution déployée (statut = Enabled)
- [ ] CloudFront : Compress = No sur le default behavior
- [ ] Frontend : `NEXT_PUBLIC_API_URL` pointe vers CloudFront
- [ ] Test SSE end-to-end : feedback IA arrive token par token
- [ ] Elastic IP associée à l'instance (pas de coût fantôme)
