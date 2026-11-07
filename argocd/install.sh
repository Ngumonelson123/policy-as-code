#!/usr/bin/env bash
# Installs a lightweight Argo CD into the demo cluster and registers the
# Application that syncs deploy/ from your Git repository.
#
# Requires: kubectl, helm, and a cluster from cluster/bootstrap.sh
#
# Environment variables:
#   REPO_URL   (required) e.g. https://github.com/<you>/policy-as-code-dpa.git
#              The repo must be public, or added to Argo CD with credentials.
#   REVISION   branch to track (default: main)
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "ERROR: do not run this with sudo/as root. Run it as your normal user." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-}"
REVISION="${REVISION:-main}"

for tool in kubectl helm; do
  path="$(command -v "${tool}" || true)"
  [[ -n "${path}" ]] || { echo "ERROR: '${tool}' is not installed or not on PATH." >&2; exit 1; }
  [[ -x "${path}" ]] || { echo "ERROR: ${path} is not executable. Run: chmod +x ${path}" >&2; exit 1; }
done
[[ -n "${REPO_URL}" ]] || { echo "ERROR: set REPO_URL, e.g. export REPO_URL=https://github.com/<you>/policy-as-code-dpa.git" >&2; exit 1; }

echo "==> Installing Argo CD (Dex and notifications disabled to save memory)"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --wait --timeout 10m

echo "==> Registering the Application (repo: ${REPO_URL}, branch: ${REVISION})"
sed -e "s|REPLACE_WITH_GIT_REMOTE|${REPO_URL}|" \
    -e "s|targetRevision: main|targetRevision: ${REVISION}|" \
    "${SCRIPT_DIR}/application.yaml" | kubectl apply -f -

echo "==> Waiting for the first sync"
for _ in $(seq 1 30); do
  sync="$(kubectl get application policy-as-code-dpa-demo -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl get application policy-as-code-dpa-demo -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  echo "    sync=${sync:-?} health=${health:-?}"
  [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]] && break
  sleep 10
done

password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
echo ""
echo "Argo CD is installed."
echo "  UI:       kubectl port-forward svc/argocd-server -n argocd 8443:443   ->  https://localhost:8443"
echo "  Login:    admin / ${password:-<see argocd-initial-admin-secret>}"
echo "  Status:   kubectl get application -n argocd"
echo "  Workload: kubectl get deploy,pods -n demo-fintech -l app=dpa-app"
