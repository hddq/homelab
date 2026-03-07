# 🏠 Homelab

Personal homelab running on Proxmox, managed fully as **Infrastructure as Code**.
The goal is to never touch a server manually — if it's not in Git, it doesn't exist.

[![CI - Kubernetes](https://github.com/hddq/homelab/actions/workflows/ci-k8s.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-k8s.yaml)
[![CI - Ansible](https://github.com/hddq/homelab/actions/workflows/ci-ansible.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-ansible.yaml)
[![CI - Nix](https://github.com/hddq/homelab/actions/workflows/ci-nix.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-nix.yaml)
[![CI - Lint](https://github.com/hddq/homelab/actions/workflows/ci-lint.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-lint.yaml)
[![CI - Gitleaks](https://github.com/hddq/homelab/actions/workflows/ci-gitleaks.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-gitleaks.yaml)

---

## ⚙️ Stack

| Layer              | Tool                           | Purpose                                        |
| ------------------ | ------------------------------ | ---------------------------------------------- |
| Hypervisor         | Proxmox VE                     | VM management                                  |
| Provisioning       | Ansible + Cloud-Init           | VM cloning, k3s install, kubeconfig            |
| Kubernetes         | k3s                            | Lightweight k8s distribution                   |
| GitOps             | ArgoCD                         | Syncs cluster state from this repo             |
| Ingress            | Traefik (built-in k3s)         | Reverse proxy + TLS termination                |
| Load Balancer      | MetalLB (BGP)                  | Bare-metal LoadBalancer IPs via BGP to OpenWRT |
| Storage            | Longhorn                       | Distributed block storage with replication     |
| TLS                | cert-manager + DuckDNS webhook | Wildcard Let's Encrypt cert via DNS-01         |
| Secrets            | Bitnami Sealed Secrets         | Encrypted secrets safe to commit to Git        |
| Monitoring         | kube-prometheus-stack          | Prometheus + Grafana                           |
| DNS                | Unbound                        | Recursive, validating, caching DNS resolver    |
| Dev environment    | Nix flake                      | Reproducible shell with all tools pinned       |
| Dependency updates | Renovate                       | Automated PRs for image/chart/k3s updates      |

---

## 🏗️ Architecture

### GitOps Flow

```
Git push
  └─▶ GitHub Actions (lint, validate, security scan)
        └─▶ ArgoCD detects drift
              └─▶ Applies changes to cluster
```

ArgoCD uses the **App of Apps** pattern: a single root `Application` in `bootstrap.yaml` manages all other applications defined in `bootstrap/`. Each app points to its own directory in `apps/` or `infrastructure/`.

### Cluster Topology

```
Proxmox (z690)
  ├── k8s-cp-1  (192.168.20.111) — control plane only, tainted NoSchedule
  ├── k8s-worker-1 (192.168.20.112) — worker
  └── k8s-worker-2 (192.168.20.113) — worker

MetalLB IP pool: 192.168.41.10 - 192.168.41.250 (BGP → OpenWRT)
Traefik LoadBalancer: 192.168.41.10
```

### Secret Management

Secrets are encrypted with `kubeseal` using the cluster's public key and stored as `SealedSecret` manifests in Git. The controller decrypts them at runtime — no plaintext secrets ever touch the repo.

---

## 📁 Repository Structure

```
.
├── ansible/                # VM provisioning + k3s install playbooks
├── bootstrap/              # ArgoCD App of Apps definitions
├── apps/                   # User-facing workloads
├── infrastructure/         # Cluster-level infrastructure (Helm wrappers)
├── scripts/                # One-off jobs (e.g. data migrations)
├── flake.nix               # Nix dev shell (all CLI tools pinned)
├── bootstrap.yaml          # Root ArgoCD Application (App of Apps entry point)
├── k3s_version.txt         # Single source of truth for k3s version (used by Ansible + Renovate)
└── renovate.json           # Renovate bot config
```

---

## 🔁 Reprovisioning from Scratch

Full cluster rebuild order using the Ansible playbooks. Assumes Proxmox is up with a VM template at ID `299`.

> 🔑 **Before you start:** Make sure the Sealed Secrets master key backup is somewhere safe and accessible. Without it, all `SealedSecret` manifests in the repo are unrecoverable after step 5.

**Step 1 — Enter dev shell:**

```bash
nix develop  # or: direnv allow
```

**Step 2 — Create secrets file:**

```bash
cp ansible/secrets.yaml.example ansible/secrets.yaml
# Fill in proxmox_api_token_secret
```

**Step 3 — Provision VMs:**

```bash
cd ansible
ansible-playbook playbooks/01-provision.yaml
```

**Step 4 — Install k3s:**

```bash
ansible-playbook playbooks/02-k3s-install.yaml
# kubeconfig is saved to ./kubeconfig
export KUBECONFIG=$(pwd)/../kubeconfig
```

**Step 5 — Restore Sealed Secrets master key:**

```bash
ansible-playbook playbooks/03-restore-sealed-secrets.yaml
```

> ⚠️ This must happen **before** ArgoCD deploys anything, otherwise all SealedSecrets will fail to decrypt.

**Step 6 — Deploy ArgoCD + bootstrap:**

```bash
ansible-playbook playbooks/04-setup-infra.yaml
```

ArgoCD will now sync everything else automatically from this repo. Done. ✅

---

## 🔒 CI / Pre-commit

| Check              | Tool                         | What it validates                             |
| ------------------ | ---------------------------- | --------------------------------------------- |
| K8s manifests      | kubeconform                  | Schema validation against k3s version         |
| API deprecations   | Pluto                        | Catches deprecated/removed k8s APIs           |
| Security misconfig | Trivy                        | IaC misconfiguration scan (CRITICAL/HIGH)     |
| Ansible            | ansible-lint                 | Ansible best practices                        |
| YAML               | yamllint                     | YAML formatting                               |
| Nix                | alejandra + statix + deadnix | Nix formatting, linting, dead code            |
| Secrets            | Gitleaks                     | Prevents secret leaks (pre-commit + daily CI) |

Pre-commit hooks run `gitleaks` and `yamllint` on every commit locally.

---

## 🛠️ Dev Environment

Uses a [Nix flake](./flake.nix) for a fully reproducible dev shell with all tools pinned:

```bash
nix develop
# or with direnv:
direnv allow
```

Includes: `kubectl`, `helm`, `kubeseal`, `argocd`, `kubeconform`, `trivy`, `pluto`, `gitleaks`, `yamllint`, `kubectx`, `pre-commit`, and the full Ansible stack in a venv.
