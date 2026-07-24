# k3s-gitops-lab

Cluster Kubernetes léger (k3s) piloté par GitOps via ArgoCD. Toute modification d'infrastructure ou d'application passe par ce dépôt — ArgoCD synchronise automatiquement l'état du cluster avec l'état Git.

---

## Architecture générale

```
Internet
   │
   ▼
Cloudflare Tunnel (cloudflared)
   │
   ▼
Traefik (Ingress Controller — intégré à k3s)
   │
   ├── argocd.thysmadev.fr    → ArgoCD
   ├── harbor.thysmadev.fr    → Harbor (registry)
   ├── grafana.thysmadev.fr   → Grafana
   ├── headlamp.thysmadev.fr  → Headlamp (dashboard)
   ├── infisical.thysmadev.fr → Infisical (secrets)
   ├── giiveaway.fr           → Giiveaway Frontend
   └── api.giiveaway.fr       → Giiveaway API
```

---

## GitOps — ArgoCD

ArgoCD orchestre tous les déploiements via le pattern **App of Apps** : une application racine (`root-app`) surveille le dossier `argocd/applications/` et crée automatiquement toutes les autres applications.

### Ordre de déploiement (sync-waves)

| Wave | Application | Description |
|------|-------------|-------------|
| 0 | `infisical` | Infisical self-hosted (gestion des secrets) |
| 0 | `infisical-operator` | Opérateur Kubernetes Infisical (CRDs + sync des secrets) |
| 1 | `infisical-config` | `InfisicalConnection` + `InfisicalAuth` partagés (`infra/infisical/`) |
| 1 | `infra` | Infrastructure transverse (cert-manager, cloudflared, ingresses, headlamp) |
| 1 | `harbor` | Registry de conteneurs |
| 1 | `monitoring` | Stack Prometheus + Grafana |
| 2 | `authentapp` | Application d'authentification |
| 2 | `giiveaway` | Application Giiveaway |

### Accès ArgoCD

| URL | `https://argocd.thysmadev.fr` |
|-----|-------------------------------|

---

## Infrastructure (`infra/`)

### Cert-Manager

Gestion automatique des certificats TLS internes via une CA auto-signée.

- **ClusterIssuer** `selfsigned-issuer` — génère la CA racine
- **ClusterIssuer** `ca-issuer` — émet les certificats pour les services internes

### Cloudflared

Tunnel Cloudflare Zero Trust permettant d'exposer les services du cluster sur Internet sans ouvrir de ports entrants. Tourne en 2 réplicas pour la haute disponibilité.

- Le token de tunnel est stocké dans un secret **Infisical** (`cloudflared-token`)

### Traefik

Ingress controller natif de k3s. Toutes les routes HTTP/HTTPS passent par lui. Entrypoint utilisé : `websecure` (443).

### Headlamp

Dashboard Kubernetes accessible via navigateur.

| URL | `https://headlamp.thysmadev.fr` |
|-----|---------------------------------|
| Namespace | `headlamp` |

#### Accès utilisateur

Les comptes sont définis dans [`infra/headlamp/users.yaml`](infra/headlamp/users.yaml). Pour ajouter un utilisateur, ajouter un bloc `ServiceAccount` + `ClusterRoleBinding` et pusher.

Rôles disponibles :

| Rôle Kubernetes | Accès |
|-----------------|-------|
| `view` | Lecture seule sur tout le cluster |
| `edit` | Lecture + écriture (hors RBAC) |
| `admin` | Lecture + écriture + RBAC (par namespace) |
| `cluster-admin` | Accès total |

Génération d'un token pour un utilisateur :

```bash
kubectl create token <nom-utilisateur> -n headlamp --duration=720h
```

---

## Observabilité (`infra/monitoring/`)

Stack déployée via le chart Helm **kube-prometheus-stack**.

| Composant | Rôle |
|-----------|------|
| **Prometheus** | Collecte des métriques (rétention 15 jours, 10 Gi) |
| **Grafana** | Visualisation des dashboards |
| **Alertmanager** | Gestion des alertes |
| **Node Exporter** | Métriques système des nœuds |
| **kube-state-metrics** | Métriques des objets Kubernetes |

| URL Grafana | `https://grafana.thysmadev.fr` |
|-------------|-------------------------------|
| Login | `admin` |

Dashboards recommandés : **Kubernetes / Compute Resources / Cluster** pour une vue globale.

> Les composants kube-controller-manager, kube-scheduler, kube-etcd et kube-proxy sont désactivés — ils sont intégrés dans le binaire k3s et non exposés séparément.

---

## Registry — Harbor (`infra/harbor/`)

Registry de conteneurs privé avec scan de vulnérabilités (Trivy).

| URL | `https://harbor.thysmadev.fr` |
|-----|-------------------------------|
| Login | `admin` |
| Chart Helm | `harbor` v1.14.0 |

Les images des applications sont stockées ici et tirées via le secret `harbor-pull-secret` présent dans chaque namespace applicatif.

---

## Applications

### Giiveaway (`apps/giiveaway/`)

Application de gestion de giveaways. Composée de :

| Composant | Image | URL |
|-----------|-------|-----|
| Frontend | `harbor.thysmadev.fr/giiveaway/front` | `https://giiveaway.fr` |
| API (Node.js) | `harbor.thysmadev.fr/giiveaway/api` | `https://api.giiveaway.fr` |
| PostgreSQL | `postgres` | Interne |
| pgAdmin | `pgadmin4` | Interne |

Les secrets (DATABASE_URL, JWT, Brevo, Google OAuth, Cloudinary) sont gérés via **Infisical** et synchronisés dans le cluster par [`apps/giiveaway/infisical-secret.yaml`](apps/giiveaway/infisical-secret.yaml).

### Authentapp (`authentapp/`)

Application d'authentification Node.js avec JWT. Composée de :

| Composant | Image | URL |
|-----------|-------|-----|
| API (Node.js) | `thysma/authent-app:1.0.0` | `authent-app.cluster.local` (interne) |
| MongoDB | `mongo` | Interne |
| Mongo Express | `mongo-express` | Interne |

Tourne en **2 réplicas**. Les secrets MongoDB et JWT sont gérés via **Infisical**.

---

## Gestion des secrets — Infisical

Les secrets ne sont plus chiffrés dans Git (Sealed Secrets a été retiré). Ils vivent dans une instance **Infisical self-hosted**, déployée dans le cluster, et sont synchronisés vers de vrais `Secret` Kubernetes par l'**Infisical Kubernetes Operator**.

```
┌─────────────────────────┐        ┌──────────────────────┐
│ Infisical (self-hosted) │◄───────┤ Infisical Operator   │
│ ns: infisical            │  API   │ (CRDs v1beta1)        │
│ Postgres + Redis inclus  │        └──────────┬───────────┘
└───────────┬──────────────┘                   │ crée/maintient
            │ UI                               ▼
            ▼                         Secret Kubernetes natif
   https://infisical.thysmadev.fr     (giiveaway-secrets, mongo-secret, …)
```

### Composants

| Application ArgoCD | Wave | Rôle |
|--------------------|------|------|
| `infisical` | 0 | Chart Helm `infisical-standalone` (backend + Postgres + Redis bundlés) |
| `infisical-operator` | 0 | Chart Helm `secrets-operator` (CRDs `InfisicalConnection`/`InfisicalAuth`/`InfisicalStaticSecret`) |
| `infisical-config` | 1 | [`infra/infisical/`](infra/infisical/) : `InfisicalConnection` + `InfisicalAuth` partagés par toutes les apps |

Chaque application définit ensuite ses propres `InfisicalStaticSecret` (ex. [`apps/giiveaway/infisical-secret.yaml`](apps/giiveaway/infisical-secret.yaml)), qui référencent le `InfisicalAuth` partagé et créent un `Secret` Kubernetes classique — aucune modification des `Deployment` existants n'a été nécessaire (`secretKeyRef`/`envFrom` pointent toujours vers les mêmes noms de secrets).

### Bootstrap initial (une seule fois, hors Git)

1. **Secret racine d'Infisical** — à créer manuellement sur le cluster avant le premier sync (jamais commité) :

   ```bash
   kubectl create namespace infisical
   kubectl create secret generic infisical-secrets -n infisical \
     --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 16)" \
     --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" \
     --from-literal=SITE_URL="https://infisical.thysmadev.fr"
   ```

   Sauvegarder `ENCRYPTION_KEY` en dehors du cluster (dans un password manager) : sans elle, les secrets stockés dans Postgres ne sont plus déchiffrables, même en cas de restauration de la base.

2. Ajouter la route `infisical.thysmadev.fr` dans le tunnel Cloudflare (dashboard Zero Trust, comme pour `argocd`/`harbor`), puis laisser ArgoCD synchroniser `infisical` + `infisical-operator` (wave 0).

3. Ouvrir `https://infisical.thysmadev.fr`, créer le compte admin et l'organisation via l'assistant de première connexion.

4. Créer un projet nommé (slug) **`k3s-gitops-lab`**, avec un environnement **`prod`** (les environnements `dev`/`staging` par défaut peuvent être supprimés ou ignorés).

5. Dans ce projet, créer une **Machine Identity** (Settings > Machine Identities), avec la méthode d'auth **Universal Auth**, et lui donner accès en lecture au projet `k3s-gitops-lab` / environnement `prod`. Récupérer le `Client ID` et générer un `Client Secret`.

6. Stocker ces identifiants dans un secret Kubernetes (jamais commité) :

   ```bash
   kubectl create secret generic infisical-machine-identity -n infisical \
     --from-literal=clientId="<client-id>" \
     --from-literal=clientSecret="<client-secret>"
   ```

7. Laisser ArgoCD synchroniser `infisical-config` (wave 1) : le `InfisicalAuth` doit passer `Ready`.

8. Recréer, dans l'UI Infisical (chemins ci-dessous), les valeurs actuellement présentes dans le cluster. Le script [`scripts/migrate-secrets-to-infisical.sh`](scripts/migrate-secrets-to-infisical.sh) automatise cette étape : il lit chaque `Secret` déjà déchiffré sur le cluster (via `kubectl`) et pousse ses clés dans Infisical (via la CLI `infisical`), au bon chemin.

   | Secret Kubernetes | Chemin Infisical (env `prod`) |
   |--------------------|-------------------------------|
   | `giiveaway/harbor-pull-secret` | `/giiveaway/harbor-pull-secret` (clé `dockerconfigjson`) |
   | `giiveaway/giiveaway-secrets` | `/giiveaway/giiveaway-secrets` |
   | `michelin/michelin-secrets` | `/michelin/michelin-secrets` |
   | `authent-app/mongo-secret` | `/authent-app/mongo-secret` |
   | `authent-app/authent-app-secrets` | `/authent-app/authent-app-secrets` |
   | `cloudflare-ddns/cloudflare-ddns-token` | `/cloudflare-ddns/cloudflare-ddns-token` |
   | `cloudflared/cloudflared-token` | `/cloudflared/cloudflared-token` |

   > ⚠️ Le déploiement `apps/michelin/backend.yaml` référence un secret `backend-secret` (clé `DATABASE_URL`) qui n'a jamais été un Sealed Secret suivi dans Git — c'est un secret créé manuellement sur le cluster, préexistant à cette migration. Il n'est pas couvert par `michelin-secrets` ni par le script de migration ; à traiter séparément si besoin.

9. Une fois les valeurs présentes dans Infisical, laisser ArgoCD synchroniser les apps (wave 2) : chaque `InfisicalStaticSecret` crée son `Secret` Kubernetes, identique en nom/clés à l'ancien Sealed Secret.

### Ajouter un nouveau secret

1. Créer le chemin/les clés dans l'UI Infisical (projet `k3s-gitops-lab`, environnement `prod`).
2. Ajouter un manifeste `InfisicalStaticSecret` dans le dossier de l'app concernée, sur le modèle de [`apps/giiveaway/infisical-secret.yaml`](apps/giiveaway/infisical-secret.yaml), en réutilisant le `InfisicalAuth` partagé (`machine-identity` / ns `infisical`).
3. Committer — ArgoCD crée le `Secret` Kubernetes correspondant.

---

## Structure du dépôt

```
.
├── argocd/
│   └── applications/       # Définitions des Applications ArgoCD
├── infra/
│   ├── cert-manager/       # ClusterIssuers TLS
│   ├── cloudflared/        # Tunnel Cloudflare
│   ├── cloudflare-ddns/    # Mise à jour DNS dynamique Cloudflare
│   ├── infisical/          # InfisicalConnection + InfisicalAuth partagés
│   ├── headlamp/           # Dashboard Kubernetes + comptes utilisateurs
│   ├── harbor/             # Values Helm du registry
│   ├── ingresses/          # Ingresses publics (*.thysmadev.fr)
│   └── monitoring/         # Values Helm Prometheus + Grafana
├── apps/
│   ├── giiveaway/          # Manifests de l'app Giiveaway
│   └── michelin/           # Manifests de l'app Michelin
├── authentapp/              # Manifests de l'app Authentapp
└── scripts/
    └── migrate-secrets-to-infisical.sh  # Migration des anciens secrets vers Infisical
```
