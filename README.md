# Policy as Code for Data Protection

Enforcing Kenya's DPA with Kyverno and Sigstore — a fully open source demo
built for **OpenInfra Days Kenya 2026**.

## What this shows

A small Kubernetes pipeline where data-protection obligations are enforced
as code, not checked after the fact:

1. **Build** the sample app and generate an SBOM (Syft)
2. **Scan** it for vulnerabilities (Trivy)
3. **Sign** it (Sigstore Cosign)
4. **Admit or reject** it at the cluster boundary with Kyverno policies

Every tool here is open source and OSI-licensed. See
[`docs/dpa-control-mapping.md`](docs/dpa-control-mapping.md) for how each
policy maps to a DPA-style obligation.

## Quickstart (short version)

```bash
./cluster/bootstrap.sh                                      # kind cluster + Kyverno + policies
./scripts/generate-cosign-key.sh                            # keypair, written into the signing policy
export IMAGE_REPO=ghcr.io/<your-github-user>/policy-as-code-dpa-app
./scripts/sign-and-scan.sh                                  # build, SBOM, scan, push, sign
./scripts/verify-demo.sh                                    # apply workloads, check every result
```

For a first run, follow the full walkthrough below.

## Full deployment walkthrough

### 0. Prerequisites

You need `docker`, `kubectl`, `helm`, `kind`, `cosign`, `syft`, `trivy` and
`python3`. To install the tools that are often missing into `~/.local/bin`:

```bash
mkdir -p ~/.local/bin
curl -Lo ~/.local/bin/kind   https://github.com/kubernetes-sigs/kind/releases/download/v0.29.0/kind-linux-amd64
curl -Lo ~/.local/bin/cosign https://github.com/sigstore/cosign/releases/download/v2.5.3/cosign-linux-amd64
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b ~/.local/bin
curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b ~/.local/bin
chmod +x ~/.local/bin/*
export PATH=~/.local/bin:$PATH   # also add this to ~/.bashrc
```

Check they all run:

```bash
kind version && cosign version && syft version && trivy --version
```

The cluster is a single kind node, so about 2 GB of free RAM is enough. To
save a little more memory, run step 1 with `INSTALL_POLICY_REPORTER=false`.

### 1. Create the cluster and install Kyverno

```bash
./cluster/bootstrap.sh
```

This creates the kind cluster, installs Kyverno (plus the Policy Reporter UI),
and applies the policies. On a first run, it skips `require-signed-images`
because no Cosign key exists yet. Step 2 applies that policy.

To check it worked:

```bash
kubectl get pods -n kyverno     # all Running
kubectl get clusterpolicy       # 3 policies Ready (4 after step 2)
```

### 2. Generate a signing key

```bash
./scripts/generate-cosign-key.sh
```

You'll be asked for a key password. Remember it, because step 4 asks for it
again. The script:

- creates `cosign.key` (private, git-ignored) and `cosign.pub` (public)
- writes `cosign.pub` into
  [`policies/require-signed-images.yaml`](policies/require-signed-images.yaml)
- applies that policy to the cluster

```bash
kubectl get clusterpolicy       # all 4 policies READY = True
```

### 3. Log in to the registry

The signing policy only checks images that match
`ghcr.io/*/policy-as-code-dpa*`, so push to GitHub Container Registry. You
need a GitHub personal access token (classic) with the `write:packages` scope.

```bash
export GH_USER=<your-github-username>
echo <your-token> | docker login ghcr.io -u "$GH_USER" --password-stdin
export IMAGE_REPO=ghcr.io/$GH_USER/policy-as-code-dpa-app
```

Keep `IMAGE_REPO` exported in this terminal. Steps 4–6 use it.

### 4. Build, scan, push and sign

```bash
./scripts/sign-and-scan.sh
```

The script:

1. builds the `:signed` image, plus an `:unsigned` image with a different
   digest
2. writes the SBOM to `docs/sbom.spdx.json` and the Trivy report to
   `docs/trivy-report.txt`
3. pushes both images
4. signs only the `:signed` digest with `cosign.key`, without using the
   public transparency log
5. verifies that `:signed` passes and `:unsigned` fails

**After the first push**, open GitHub → your profile → *Packages* →
`policy-as-code-dpa-app` → *Package settings* and set the visibility to
**Public**. Kyverno and the kind node have to pull the image, and they have no
GHCR credentials.

Options: `FAIL_ON_VULNS=1` fails the run on HIGH/CRITICAL findings.
`SIGNING_MODE=keyless` uses public Sigstore instead, but the policy rejects
images signed that way.

### 5. Point the manifests at your image

```bash
sed -i "s|ghcr.io/REPLACE_ORG/policy-as-code-dpa-app|$IMAGE_REPO|g" \
  manifests/compliant/*.yaml manifests/non-compliant/*.yaml
```

(`verify-demo.sh` does this substitution automatically. You only need this
step to run the `kubectl apply` commands below by hand.)

### 6. Run the demo

The automated check applies everything and reports PASS or FAIL for each
expected result:

```bash
./scripts/verify-demo.sh
```

Or do it by hand on stage:

```bash
kubectl apply -f manifests/namespace.yaml

kubectl apply -f manifests/compliant/pod.yaml                                     # admitted
kubectl apply -f manifests/compliant/pod-restricted-data.yaml                     # admitted
kubectl apply -f manifests/non-compliant/pod-unsigned-image.yaml                  # rejected
kubectl apply -f manifests/non-compliant/pod-missing-labels.yaml                  # rejected
kubectl apply -f manifests/non-compliant/pod-privileged-root.yaml                 # rejected
kubectl apply -f manifests/non-compliant/pod-restricted-unapproved-namespace.yaml # rejected
```

| Manifest | Expected | Policy that decides |
|---|---|---|
| `compliant/pod.yaml` | Admitted | All pass |
| `compliant/pod-restricted-data.yaml` | Admitted | `restrict-to-approved-namespaces` (demo-fintech is approved) |
| `non-compliant/pod-unsigned-image.yaml` | Rejected | `require-signed-images` |
| `non-compliant/pod-missing-labels.yaml` | Rejected | `require-data-classification-labels` |
| `non-compliant/pod-privileged-root.yaml` | Rejected | `restrict-privileged-workloads` |
| `non-compliant/pod-restricted-unapproved-namespace.yaml` | Rejected | `restrict-to-approved-namespaces` (demo-sandbox isn't approved) |

To inspect the results:

```bash
# Kyverno rewrites the admitted image from its tag to the digest it verified (@sha256:…)
kubectl get pod compliant-app -n demo-fintech -o jsonpath='{.spec.containers[0].image}'; echo
kubectl get pods -n demo-fintech        # compliant pods Running
kubectl get policyreport -A
```

To open the Policy Reporter UI:

```bash
kubectl port-forward -n kyverno svc/policy-reporter-ui 8082:8080
# open http://localhost:8082
```

To rerun the demo, delete the demo namespaces first:

```bash
kubectl delete -f manifests/namespace.yaml
```

### 7. (Optional) Deploy through Argo CD

Replace `REPLACE_WITH_GIT_REMOTE` in
[`argocd/application.yaml`](argocd/application.yaml), install Argo CD in the
cluster, and apply the manifest. Argo CD then syncs `manifests/compliant`,
and Kyverno enforces the policies the same way.

### 8. Clean up

```bash
kind delete cluster --name policy-as-code-dpa
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `kind create cluster` fails with "node(s) already exist" | A half-created cluster is left over. Run `kind delete cluster --name policy-as-code-dpa` and rerun step 1. |
| A compliant pod is rejected by `require-signed-images` with a fetch or `UNAUTHORIZED` error | The GHCR package is still private. Make it public (step 4). |
| A compliant pod is rejected with "no matching signatures" | It was signed with a different key from the one in the policy. Rerun step 2 (it reuses the existing key) and then step 4. |
| `require-signed-images` is missing from `kubectl get clusterpolicy` | Step 2 hasn't run yet, or ran before the cluster existed. Run `kubectl apply -f policies/require-signed-images.yaml`. |
| Pod admitted but stuck in `ImagePullBackOff` | The package is private, or `IMAGE_REPO` doesn't match what you pushed. |
| Kyverno pods `Pending` or `OOMKilled` | Not enough memory. Rerun step 1 with `INSTALL_POLICY_REPORTER=false`, and close other containers. |

## Repo layout

```
cluster/      kind cluster config + bootstrap script (installs Kyverno)
policies/     Kyverno ClusterPolicies, one per control
pipeline/     Sample app + Dockerfile used to demo the build/sign chain
scripts/      Key generation, sign-and-scan pipeline, end-to-end verification
manifests/    Demo namespaces + compliant and non-compliant workloads
argocd/       Optional GitOps Application manifest
docs/         DPA-to-control mapping, generated SBOM/scan reports
```

A CI workflow (build, SBOM, scan and sign on every push) is planned but not
yet in the repo.

## Before you reuse this

- Set `IMAGE_REPO` to your own registry, and replace `REPLACE_WITH_GIT_REMOTE`
  in `argocd/application.yaml` if you use Argo CD.
- `docs/dpa-control-mapping.md` is an engineering interpretation, not legal
  advice — have your compliance team review it before relying on it.
- Policies are set to `Enforce`. Switch each rule's `failureAction` to `Audit`
  while you're testing changes so you don't lock yourself out of your own
  cluster.

## License

Apache 2.0 — see [LICENSE](LICENSE). Reuse the policies freely.
