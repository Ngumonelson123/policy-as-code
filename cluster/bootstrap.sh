#!/usr/bin/env bash
# Bootstraps a local demo cluster and installs Kyverno + the policies.
# Requires: kind, kubectl, helm
#
# Optional environment variables:
#   INSTALL_POLICY_REPORTER=false   skip the Policy Reporter UI (saves memory)
#   KYVERNO_CHART_VERSION=<ver>     pin the Kyverno Helm chart version
set -euo pipefail

if [[ "${EUID}" -eq 0 ]]; then
  echo "ERROR: do not run this with sudo/as root. Run it as your normal user (who must be able to run docker)." >&2
  exit 1
fi

CLUSTER_NAME="policy-as-code-dpa"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${SCRIPT_DIR}/../policies"
INSTALL_POLICY_REPORTER="${INSTALL_POLICY_REPORTER:-true}"

for tool in kind kubectl helm; do
  path="$(command -v "${tool}" || true)"
  [[ -n "${path}" ]] || { echo "ERROR: '${tool}' is not installed or not on PATH." >&2; exit 1; }
  [[ -x "${path}" ]] || { echo "ERROR: ${path} is not executable. Run: chmod +x ${path}" >&2; exit 1; }
done

echo "==> Creating kind cluster (${CLUSTER_NAME})"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "    Cluster already exists, skipping creation."
else
  kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

echo "==> Installing Kyverno via Helm"
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo update kyverno >/dev/null
version_args=()
if [[ -n "${KYVERNO_CHART_VERSION:-}" ]]; then
  version_args=(--version "${KYVERNO_CHART_VERSION}")
fi
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  "${version_args[@]}" \
  --wait --timeout 10m

echo "==> Waiting for Kyverno to be ready"
kubectl wait --for=condition=available --timeout=300s \
  deployment -l app.kubernetes.io/instance=kyverno -n kyverno

if [[ "${INSTALL_POLICY_REPORTER}" == "true" ]]; then
  echo "==> Installing the Kyverno Policy Reporter (optional UI for policy reports)"
  # Policy Reporter is published in its own Helm repo, not the kyverno one.
  helm repo add policy-reporter https://kyverno.github.io/policy-reporter --force-update >/dev/null
  helm repo update policy-reporter >/dev/null
  # Optional component: warn instead of aborting the bootstrap if it fails.
  if ! helm upgrade --install policy-reporter policy-reporter/policy-reporter \
      --namespace kyverno \
      --set ui.enabled=true \
      --wait --timeout 10m; then
    echo "    WARNING: Policy Reporter failed to install. Continuing without the UI."
  fi
else
  echo "==> Skipping Policy Reporter (INSTALL_POLICY_REPORTER=${INSTALL_POLICY_REPORTER})"
fi

echo "==> Applying policies"
for policy in "${POLICY_DIR}"/*.yaml; do
  if grep -q "REPLACE_WITH_COSIGN_PUBLIC_KEY" "${policy}"; then
    echo "    SKIPPING $(basename "${policy}"): no Cosign public key yet."
    echo "    Run scripts/generate-cosign-key.sh — it fills in the key and applies the policy."
    continue
  fi
  kubectl apply -f "${policy}"
done

echo "==> Waiting for policies to become ready"
kubectl wait --for=condition=Ready clusterpolicy --all --timeout=120s

echo ""
echo "Cluster is ready. Kyverno and the policies are installed."
echo "Next:"
echo "  1. scripts/generate-cosign-key.sh   (if you haven't already)"
echo "  2. scripts/sign-and-scan.sh         (build, SBOM, scan, push, sign)"
echo "  3. scripts/verify-demo.sh           (apply the demo workloads and check results)"
