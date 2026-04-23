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
   ├── giiveaway.fr           → Giiveaway Frontend
   └── api.giiveaway.fr       → Giiveaway API
```

---

## GitOps — ArgoCD

ArgoCD orchestre tous les déploiements via le pattern **App of Apps** : une application racine (`root-app`) surveille le dossier `argocd/applications/` et crée automatiquement toutes les autres applications.

### Ordre de déploiement (sync-waves)

| Wave | Application | Description |
|------|-------------|-------------|
| 0 | `sealed-secrets` | Contrôleur de déchiffrement des secrets |
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

- Le token de tunnel est stocké dans un **Sealed Secret** (`cloudflared-token`)

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

Les secrets (DATABASE_URL, JWT, Brevo, Google OAuth, Cloudinary) sont chiffrés via **Sealed Secrets** dans [`apps/giiveaway/sealed-secret.yaml`](apps/giiveaway/sealed-secret.yaml).

### Authentapp (`authentapp/`)

Application d'authentification Node.js avec JWT. Composée de :

| Composant | Image | URL |
|-----------|-------|-----|
| API (Node.js) | `thysma/authent-app:1.0.0` | `authent-app.cluster.local` (interne) |
| MongoDB | `mongo` | Interne |
| Mongo Express | `mongo-express` | Interne |

Tourne en **2 réplicas**. Les secrets MongoDB et JWT sont chiffrés via **Sealed Secrets**.

---

## Gestion des secrets — Sealed Secrets

Tous les secrets Kubernetes sont chiffrés avec **Bitnami Sealed Secrets** (v2.16.1) avant d'être commités dans Git. Le contrôleur dans `kube-system` est le seul à pouvoir les déchiffrer.

Pour créer un nouveau secret chiffré :

```bash
kubectl create secret generic mon-secret \
  --from-literal=ma-cle=ma-valeur \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > sealed-secret.yaml
```

---

## Structure du dépôt

```
.
├── argocd/
│   └── applications/       # Définitions des Applications ArgoCD
├── infra/
│   ├── cert-manager/       # ClusterIssuers TLS
│   ├── cloudflared/        # Tunnel Cloudflare
│   ├── headlamp/           # Dashboard Kubernetes + comptes utilisateurs
│   ├── harbor/             # Values Helm du registry
│   ├── ingresses/          # Ingresses publics (*.thysmadev.fr)
│   └── monitoring/         # Values Helm Prometheus + Grafana
├── apps/
│   └── giiveaway/          # Manifests de l'app Giiveaway
└── authentapp/             # Manifests de l'app Authentapp
```
