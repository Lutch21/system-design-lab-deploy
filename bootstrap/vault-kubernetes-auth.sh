#!/usr/bin/env sh
# One-time setup: let Vault trust service-account tokens from the local kind cluster.
#
#   sh bootstrap/vault-kubernetes-auth.sh
#
# Safe to run again. Needs: the Vault container running and unsealed (`npm run vault:start` in
# the system-design-lab repo), and kubectl pointing at the kind cluster.
#
# What it sets up in Vault:
#   auth/kubernetes          The Kubernetes auth method: Vault accepts a pod's service-account
#                            token as a login, after checking it with the cluster's TokenReview API.
#   role system-design-lab   Only service account "vault-reader" in namespace "system-design-lab"
#                            may log in, and it gets policy system-design-lab-tutor (read the
#                            tutor's secret, nothing else), as a token that expires in 1 hour.
#                            The service-account token must be issued for audience "vault", so a
#                            token meant for some other system can't be replayed here.
set -eu

VAULT_CONTAINER=system-design-lab-vault
# The root token comes from the app repo's Vault setup. Override with VAULT_INIT_FILE if needed.
INIT_FILE=${VAULT_INIT_FILE:-"$(dirname "$0")/../../system-design-lab/.vault/init.json"}
NAMESPACE=system-design-lab
SERVICE_ACCOUNT=vault-reader
ROLE=system-design-lab
POLICY=system-design-lab-tutor

[ -f "$INIT_FILE" ] || { echo "Can't find $INIT_FILE. Run 'npm run vault:start' in system-design-lab first."; exit 1; }
VAULT_TOKEN=$(node -e "console.log(require(require('path').resolve('$INIT_FILE')).root_token)")
export VAULT_TOKEN

# Run the vault CLI in the container; the token is passed by name, not on the command line.
vault_cli() { docker exec -i -e VAULT_TOKEN "$VAULT_CONTAINER" vault "$@"; }

echo "1. Put Vault on the kind Docker network (so pods and Vault can reach each other)"
docker network connect kind "$VAULT_CONTAINER" 2>/dev/null || echo "   already connected"

echo "2. Enable the Kubernetes auth method"
vault_cli auth list | grep -q '^kubernetes/' && echo "   already enabled" || vault_cli auth enable kubernetes

echo "3. Tell Vault how to reach the cluster's API server and which CA certificate to trust"
# Inside the kind network, the API server is the control-plane container on port 6443.
control_plane=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
  base64 -d |
  vault_cli write auth/kubernetes/config \
    kubernetes_host="https://$control_plane:6443" \
    kubernetes_ca_cert=- >/dev/null
echo "   kubernetes_host=https://$control_plane:6443"

echo "4. Create role '$ROLE' for $NAMESPACE/$SERVICE_ACCOUNT"
vault_cli write "auth/kubernetes/role/$ROLE" \
  bound_service_account_names="$SERVICE_ACCOUNT" \
  bound_service_account_namespaces="$NAMESPACE" \
  token_policies="$POLICY" \
  audience=vault \
  token_ttl=1h >/dev/null

echo "Done. Vault will now accept logins from $NAMESPACE/$SERVICE_ACCOUNT."
