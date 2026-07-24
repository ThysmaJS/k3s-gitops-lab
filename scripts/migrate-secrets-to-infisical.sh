#!/usr/bin/env bash
# Copies the plaintext value of every Secret currently decrypted on the cluster by the
# Sealed Secrets controller into Infisical, at the paths expected by the
# InfisicalStaticSecret manifests (apps/*/infisical-secret.yaml, authentapp/infisical-secret.yaml,
# infra/cloudflare*/infisical-secret.yaml).
#
# Prerequisites:
#   - kubectl pointed at the k3s cluster (the Sealed Secrets controller must still be
#     running so the existing Secret objects are still there / still decrypted).
#   - infisical CLI installed and logged in with a user/account that has write access
#     to the "k3s-gitops-lab" project (`infisical login`), or INFISICAL_TOKEN exported.
#   - The "k3s-gitops-lab" project and its "prod" environment already created in the
#     Infisical UI (see README.md, "Gestion des secrets — Infisical" section).
#
# This script only reads from the cluster and writes to Infisical. It never prints
# secret values to stdout/logs beyond what `infisical secrets set` itself echoes.
#
# Usage:
#   PROJECT_ID=<your-project-id> ./scripts/migrate-secrets-to-infisical.sh
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to your Infisical project ID (Project Settings > Project ID)}"
ENV_SLUG="${ENV_SLUG:-prod}"

# namespace:secretName:infisicalPath
MAPPINGS=(
  "giiveaway:giiveaway-secrets:/giiveaway/giiveaway-secrets"
  "michelin:michelin-secrets:/michelin/michelin-secrets"
  "authent-app:mongo-secret:/authent-app/mongo-secret"
  "authent-app:authent-app-secrets:/authent-app/authent-app-secrets"
  "cloudflare-ddns:cloudflare-ddns-token:/cloudflare-ddns/cloudflare-ddns-token"
  "cloudflared:cloudflared-token:/cloudflared/cloudflared-token"
)

push_secret() {
  local namespace="$1" secret="$2" path="$3" infisical_key="$4" key="$5"
  local value
  value=$(kubectl get secret "$secret" -n "$namespace" -o jsonpath="{.data['$key']}" | base64 -d)
  infisical secrets set "${infisical_key}=${value}" \
    --projectId="$PROJECT_ID" --env="$ENV_SLUG" --path="$path"
}

for mapping in "${MAPPINGS[@]}"; do
  IFS=":" read -r namespace secret path <<< "$mapping"
  echo "== $namespace/$secret -> $path =="
  keys=$(kubectl get secret "$secret" -n "$namespace" -o jsonpath='{.data}' | grep -oE '"[^"]+":' | tr -d '":')
  for key in $keys; do
    echo "  - $key"
    push_secret "$namespace" "$secret" "$path" "$key" "$key"
  done
done

# harbor-pull-secret is a dockerconfigjson Secret: the single key is literally ".dockerconfigjson".
# It's stored in Infisical under the plain key "dockerconfigjson" (no leading dot), which the
# InfisicalStaticSecret template in apps/giiveaway/infisical-secret.yaml renames back on sync.
echo "== giiveaway/harbor-pull-secret -> /giiveaway/harbor-pull-secret =="
push_secret giiveaway harbor-pull-secret /giiveaway/harbor-pull-secret dockerconfigjson '.dockerconfigjson'

echo "Done. Verify the values in the Infisical UI, then apply the InfisicalStaticSecret manifests."
