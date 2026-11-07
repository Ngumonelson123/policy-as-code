#!/usr/bin/env bash
# End-to-end check: applies every demo workload and confirms Kyverno
# admits the compliant ones and rejects each non-compliant one for the
# right reason. Exits non-zero if any result is unexpected.
#
# Requires: kubectl, a cluster set up by cluster/bootstrap.sh, and images
# produced by scripts/sign-and-scan.sh.
#
# Environment variables:
#   IMAGE_REPO   (required) same value used for sign-and-scan.sh. Manifests
#                still containing REPLACE_ORG are rewritten on the fly.
#   CLEANUP      true to delete the demo namespaces at the end (default: false)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
IMAGE_REPO="${IMAGE_REPO:-}"
CLEANUP="${CLEANUP:-false}"
DEFAULT_REPO="ghcr.io/REPLACE_ORG/policy-as-code-dpa-app"

[[ -n "${IMAGE_REPO}" ]] || { echo "ERROR: set IMAGE_REPO (same value as for sign-and-scan.sh)." >&2; exit 1; }

render() { sed "s|${DEFAULT_REPO}|${IMAGE_REPO}|g" "$1"; }

pass=0; fail=0; registry_hint=false
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

# Kyverno could not reach the registry (private package / bad credentials).
# A rejection for this reason proves nothing about the policies.
# Case-sensitive on purpose: every Kyverno rejection says "...denied the request",
# while registry errors use upper-case codes ("UNAUTHORIZED:", "DENIED:").
# A missing signature (MANIFEST_UNKNOWN on the .sig tag) is a real policy failure,
# so it is deliberately not matched here.
is_registry_error() { grep -qE "UNAUTHORIZED|DENIED:|authentication required|no such host" <<<"$1"; }

echo "==> Checking policies are installed and ready"
for p in require-signed-images require-data-classification-labels \
         restrict-privileged-workloads restrict-to-approved-namespaces; do
  ready="$(kubectl get clusterpolicy "${p}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  if [[ "${ready}" == "True" ]]; then ok "policy ${p} is Ready"; else bad "policy ${p} is missing or not Ready"; fi
done

echo "==> Creating demo namespaces"
kubectl apply -f "${MANIFESTS}/namespace.yaml"

# expect_admit <manifest>
expect_admit() {
  local file="$1" name ns out
  name="$(render "${file}" | kubectl create --dry-run=client -o jsonpath='{.metadata.name}' -f -)"
  ns="$(render "${file}" | kubectl create --dry-run=client -o jsonpath='{.metadata.namespace}' -f -)"
  kubectl delete pod "${name}" -n "${ns}" --ignore-not-found --wait=true >/dev/null 2>&1
  if out="$(render "${file}" | kubectl apply -f - 2>&1)"; then
    ok "$(basename "${file}") admitted"
  else
    bad "$(basename "${file}") was rejected but should be admitted:"
    echo "${out}" | sed 's/^/          /'
    is_registry_error "${out}" && registry_hint=true
  fi
}

# expect_reject <manifest> <policy-name-expected-in-error>
expect_reject() {
  local file="$1" policy="$2" out
  if out="$(render "${file}" | kubectl apply -f - 2>&1)"; then
    bad "$(basename "${file}") was admitted but should be rejected by ${policy}"
    render "${file}" | kubectl delete -f - --ignore-not-found >/dev/null 2>&1
  elif is_registry_error "${out}"; then
    bad "$(basename "${file}") rejected only because Kyverno could not access the registry:"
    echo "${out}" | sed 's/^/          /'
    registry_hint=true
  elif grep -q "${policy}" <<<"${out}"; then
    ok "$(basename "${file}") rejected by ${policy}"
  else
    bad "$(basename "${file}") rejected, but not by ${policy}:"
    echo "${out}" | sed 's/^/          /'
  fi
}

echo "==> Compliant workloads (should be admitted)"
expect_admit "${MANIFESTS}/compliant/pod.yaml"
expect_admit "${MANIFESTS}/compliant/pod-restricted-data.yaml"

echo "==> Non-compliant workloads (should be rejected)"
expect_reject "${MANIFESTS}/non-compliant/pod-unsigned-image.yaml"                  require-signed-images
expect_reject "${MANIFESTS}/non-compliant/pod-missing-labels.yaml"                  require-data-classification-labels
expect_reject "${MANIFESTS}/non-compliant/pod-privileged-root.yaml"                 restrict-privileged-workloads
expect_reject "${MANIFESTS}/non-compliant/pod-restricted-unapproved-namespace.yaml" restrict-to-approved-namespaces

echo "==> Checking Kyverno pinned the admitted image to a verified digest"
image="$(kubectl get pod compliant-app -n demo-fintech -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
if [[ "${image}" == *@sha256:* ]]; then ok "compliant-app image is ${image}"; else bad "compliant-app image not digest-pinned (got '${image}')"; fi

if [[ "${CLEANUP}" == "true" ]]; then
  echo "==> Cleaning up demo namespaces"
  kubectl delete -f "${MANIFESTS}/namespace.yaml" --ignore-not-found
fi

if [[ "${registry_hint}" == "true" ]]; then
  echo ""
  echo "HINT: Kyverno could not pull from ${IMAGE_REPO%%/*}. If this is GHCR, make the package"
  echo "      public: GitHub -> Packages -> $(basename "${IMAGE_REPO}") -> Package settings -> Change visibility."
  echo "      Also check that sign-and-scan.sh pushed both :signed and :unsigned to ${IMAGE_REPO}."
fi

echo ""
echo "Result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
