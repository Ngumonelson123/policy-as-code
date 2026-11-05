#!/usr/bin/env bash
# Builds the demo image, generates an SBOM, scans for vulnerabilities,
# pushes it and signs it with Cosign. It also builds and pushes a second,
# deliberately UNSIGNED image so the demo can show it being rejected.
#
# Requires: docker, syft, trivy, cosign
#
# Environment variables:
#   IMAGE_REPO     (required) e.g. ghcr.io/<your-org>/policy-as-code-dpa-app
#                  Must match ghcr.io/*/policy-as-code-dpa* or Kyverno won't check it.
#   SIGNING_MODE   key (default) | keyless
#                  key     -> signs with cosign.key; this is what the Kyverno policy verifies
#                  keyless -> public Sigstore Fulcio/Rekor; the key-based policy will REJECT it
#   COSIGN_KEY     path to the private key (default: ./cosign.key)
#   COSIGN_PUB     path to the public key  (default: ./cosign.pub)
#   FAIL_ON_VULNS  1 to fail the run on HIGH/CRITICAL findings (default: 0)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_REPO="${IMAGE_REPO:-}"
SIGNING_MODE="${SIGNING_MODE:-key}"
COSIGN_KEY="${COSIGN_KEY:-${ROOT_DIR}/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-${ROOT_DIR}/cosign.pub}"
FAIL_ON_VULNS="${FAIL_ON_VULNS:-0}"

SIGNED_IMAGE="${IMAGE_REPO}:signed"
UNSIGNED_IMAGE="${IMAGE_REPO}:unsigned"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- Pre-flight checks -------------------------------------------------------
for tool in docker syft trivy cosign; do
  path="$(command -v "${tool}" || true)"
  [[ -n "${path}" ]] || die "'${tool}' is not installed or not on PATH."
  [[ -x "${path}" ]] || die "${path} is not executable. Run: chmod +x ${path}"
done
[[ -n "${IMAGE_REPO}" ]] || die "Set IMAGE_REPO, e.g. export IMAGE_REPO=ghcr.io/<your-org>/policy-as-code-dpa-app"
[[ "${IMAGE_REPO}" != *REPLACE_ORG* ]] || die "IMAGE_REPO still contains REPLACE_ORG."
if [[ "${IMAGE_REPO}" != ghcr.io/*/policy-as-code-dpa* ]]; then
  echo "WARNING: ${IMAGE_REPO} does not match the policy's imageReferences"
  echo "         (ghcr.io/*/policy-as-code-dpa*). Kyverno will not verify it."
fi
case "${SIGNING_MODE}" in
  key)
    [[ -f "${COSIGN_KEY}" ]] || die "${COSIGN_KEY} not found. Run scripts/generate-cosign-key.sh first."
    [[ -f "${COSIGN_PUB}" ]] || die "${COSIGN_PUB} not found. Run scripts/generate-cosign-key.sh first."
    ;;
  keyless) ;;
  *) die "SIGNING_MODE must be 'key' or 'keyless' (got '${SIGNING_MODE}')." ;;
esac

# ---- Build -------------------------------------------------------------------
echo "==> Building signed-candidate image: ${SIGNED_IMAGE}"
docker build -t "${SIGNED_IMAGE}" "${ROOT_DIR}/pipeline"

# A different label gives the unsigned image a different digest. Signatures
# are attached to digests, so simply re-tagging the signed image would make
# ':unsigned' carry the signature too.
echo "==> Building unsigned image (distinct digest): ${UNSIGNED_IMAGE}"
docker build --label "org.opencontainers.image.description=unsigned demo image" \
  -t "${UNSIGNED_IMAGE}" "${ROOT_DIR}/pipeline"

# ---- SBOM + scan -------------------------------------------------------------
echo "==> Generating SBOM with Syft"
syft "docker:${SIGNED_IMAGE}" -o spdx-json > "${ROOT_DIR}/docs/sbom.spdx.json"
echo "    SBOM written to docs/sbom.spdx.json"

echo "==> Scanning for vulnerabilities with Trivy"
trivy image --severity HIGH,CRITICAL --exit-code "${FAIL_ON_VULNS}" "${SIGNED_IMAGE}" \
  | tee "${ROOT_DIR}/docs/trivy-report.txt"
echo "    Report written to docs/trivy-report.txt (FAIL_ON_VULNS=${FAIL_ON_VULNS})"

# ---- Push --------------------------------------------------------------------
echo "==> Pushing images"
docker push "${SIGNED_IMAGE}"
docker push "${UNSIGNED_IMAGE}"

# Sign the immutable digest, not the mutable tag.
SIGNED_DIGEST_REF="$(docker inspect --format '{{index .RepoDigests 0}}' "${SIGNED_IMAGE}")"
echo "    Signed-candidate digest: ${SIGNED_DIGEST_REF}"

# ---- Sign + verify -----------------------------------------------------------
if [[ "${SIGNING_MODE}" == "key" ]]; then
  echo "==> Signing with ${COSIGN_KEY} (no public transparency log)"
  cosign sign --yes --key "${COSIGN_KEY}" --tlog-upload=false "${SIGNED_DIGEST_REF}"

  echo "==> Verifying signature"
  cosign verify --key "${COSIGN_PUB}" --insecure-ignore-tlog=true "${SIGNED_IMAGE}" >/dev/null
  echo "    ${SIGNED_IMAGE} verifies against ${COSIGN_PUB}"

  echo "==> Confirming the unsigned image does NOT verify"
  if cosign verify --key "${COSIGN_PUB}" --insecure-ignore-tlog=true "${UNSIGNED_IMAGE}" >/dev/null 2>&1; then
    die "${UNSIGNED_IMAGE} unexpectedly has a valid signature."
  fi
  echo "    ${UNSIGNED_IMAGE} has no valid signature (as intended)"
else
  echo "==> Signing keyless via public Sigstore Fulcio/Rekor (opens a browser login)"
  echo "    NOTE: policies/require-signed-images.yaml verifies a key, so it will reject this image."
  cosign sign --yes "${SIGNED_DIGEST_REF}"
  cosign verify "${SIGNED_IMAGE}" \
    --certificate-identity-regexp ".*" \
    --certificate-oidc-issuer-regexp ".*" >/dev/null
fi

echo ""
echo "Done."
echo "  ${SIGNED_IMAGE}   built, scanned, SBOM'd and signed"
echo "  ${UNSIGNED_IMAGE} built and pushed, intentionally unsigned"
echo "Next: scripts/verify-demo.sh"
