# Mapping DPA-style Obligations to Technical Controls

> This is an engineering interpretation written for a technical audience,
> not legal advice. Consult your organisation's legal and compliance team
> for a definitive reading of Kenya's Data Protection Act.

| Principle (common to Kenya's DPA and similar data protection laws) | What it typically asks for | Technical control in this repo |
|---|---|---|
| Integrity and confidentiality | Data and systems must be protected against unauthorised or unlawful processing, loss or damage | `require-signed-images.yaml` — only signed, verified images run |
| Accountability | You must be able to show who is responsible for a system and its data | `require-data-classification-labels.yaml` — every workload is labelled with an owner |
| Data minimisation / purpose limitation | Processing should be limited to what's necessary and declared | `data-classification` label forces a conscious declaration of data sensitivity per workload |
| Security of processing | Appropriate technical and organisational measures | `restrict-privileged-workloads.yaml` — no privileged containers, no root |
| Storage limitation / data residency | Certain data may need to stay within defined boundaries or systems | `restrict-to-approved-namespaces.yaml` — restricted/confidential workloads confined to approved namespaces |
| Demonstrable compliance | Evidence of controls, not just policy documents | Kyverno Policy Reports + SBOM (`docs/sbom.spdx.json`) + Trivy scan report, produced by `scripts/sign-and-scan.sh` and by the GitHub Actions workflow on every push (SBOM also attached to the image as a signed Cosign attestation) |

## Why policy-as-code instead of a compliance checklist

A checklist reviewed quarterly tells you whether you were compliant last
quarter. An admission-time policy tells you whether a specific deployment,
right now, meets the bar — and it produces a machine-readable record
(the Kyverno Policy Report) every time it runs. That record is the
evidence an auditor actually wants.

## Self-hosting note (data sovereignty)

By default, `scripts/sign-and-scan.sh` signs with a local Cosign keypair
created by `scripts/generate-cosign-key.sh`, and it does not upload anything
to the public Rekor transparency log. No signature metadata leaves your own
infrastructure and registry. The Kyverno policy verifies against that key.

Keyless signing through the public Sigstore Fulcio/Rekor instances is still
available (`SIGNING_MODE=keyless`), but the key-based policy in this repo
won't accept those signatures. Sigstore's components (Fulcio, Rekor) are
open source and can be self-hosted if an organisation wants the full keyless
workflow without the public instance.
