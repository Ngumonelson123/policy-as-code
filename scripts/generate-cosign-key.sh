#!/usr/bin/env bash
# Generates a Cosign keypair for teams that want to avoid the public
# Sigstore Fulcio/Rekor instance entirely — relevant for the data
# sovereignty angle of the talk.
#
# It then writes the public key into policies/require-signed-images.yaml
# and, if the demo cluster is reachable, applies that policy.
#
# Requires: cosign, python3 (kubectl optional)
# Set COSIGN_PASSWORD to choose the key password non-interactively.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
POLICY="${ROOT_DIR}/policies/require-signed-images.yaml"
cd "${ROOT_DIR}"

cosign_path="$(command -v cosign || true)"
[[ -n "${cosign_path}" ]] || { echo "ERROR: 'cosign' is not installed or not on PATH." >&2; exit 1; }
[[ -x "${cosign_path}" ]] || { echo "ERROR: ${cosign_path} is not executable. Run: chmod +x ${cosign_path}" >&2; exit 1; }

if [[ -f cosign.key && -f cosign.pub ]]; then
  echo "==> cosign.key and cosign.pub already exist — reusing them."
  echo "    Delete both files first if you want a fresh keypair."
else
  echo "==> Generating Cosign keypair"
  cosign generate-key-pair
fi

echo "==> Writing cosign.pub into ${POLICY#"${ROOT_DIR}/"}"
python3 - "${POLICY}" cosign.pub <<'PY'
import re, sys
policy_path, pub_path = sys.argv[1], sys.argv[2]
pub = open(pub_path).read().strip().splitlines()
text = open(policy_path).read()
pattern = re.compile(r"^( *)-----BEGIN PUBLIC KEY-----\n.*?-----END PUBLIC KEY-----$", re.M | re.S)
m = pattern.search(text)
if not m:
    sys.exit("ERROR: could not find a PUBLIC KEY block in " + policy_path)
indent = m.group(1)
block = "\n".join(indent + line for line in pub)
open(policy_path, "w").write(text[:m.start()] + block + text[m.end():])
PY

if command -v kubectl >/dev/null && kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  echo "==> Cluster with Kyverno detected — applying the signing policy"
  kubectl apply -f "${POLICY}"
  kubectl wait --for=condition=Ready clusterpolicy/require-signed-images --timeout=120s
else
  echo "==> No Kyverno cluster reachable — apply the policy later with:"
  echo "    kubectl apply -f policies/require-signed-images.yaml"
fi

echo ""
echo "cosign.key (private, git-ignored — keep secret) and cosign.pub (public) are ready."
echo "scripts/sign-and-scan.sh signs with cosign.key by default."
