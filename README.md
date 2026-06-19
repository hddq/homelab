<div align="center">

# 🏠 Homelab

Personal homelab running on Proxmox, managed fully as **Infrastructure as Code**.
The goal is to never touch a server manually — if it's not in Git, it doesn't exist.

[![CI - Kubernetes](https://github.com/hddq/homelab/actions/workflows/ci-k8s.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-k8s.yaml)
[![CI - Ansible](https://github.com/hddq/homelab/actions/workflows/ci-ansible.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-ansible.yaml)
[![CI - Nix](https://github.com/hddq/homelab/actions/workflows/ci-nix.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-nix.yaml)
[![CI - Lint](https://github.com/hddq/homelab/actions/workflows/ci-lint.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-lint.yaml)
[![CI - ShellCheck](https://github.com/hddq/homelab/actions/workflows/ci-shellcheck.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-shellcheck.yaml)
[![CI - Gitleaks](https://github.com/hddq/homelab/actions/workflows/ci-gitleaks.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/ci-gitleaks.yaml)

</div>

---

## ⚙️ Stack

| Layer              | Tool                           | Purpose                                        |
| ------------------ | ------------------------------ | ---------------------------------------------- |
| Hypervisor         | Proxmox VE                     | VM management                                  |
| Provisioning       | Ansible + Cloud-Init           | VM cloning, k3s install, kubeconfig            |
| Kubernetes         | k3s                            | Lightweight k8s distribution                   |
| GitOps             | ArgoCD                         | Syncs cluster state from this repo             |
| Ingress            | Traefik                        | Reverse proxy + TLS termination                |
| Load Balancer      | MetalLB (BGP)                  | Bare-metal LoadBalancer IPs via BGP to OpenWRT |
| Storage            | Longhorn                       | Distributed block storage with replication     |
| TLS                | cert-manager + DuckDNS webhook | Wildcard Let's Encrypt cert via DNS-01         |
| Secrets            | SOPS + age + ksops             | Encrypted secrets safe to commit to Git        |
| Monitoring         | VictoriaMetrics Stack          | Metrics collection, storage, alerting and dashboards   |
| Dev environment    | Nix flake                      | Reproducible shell with all tools pinned       |
| Dependency updates | Renovate                       | Automated PRs for image/chart/k3s updates      |
| Source Control     | GitHub                         | Hosts GitOps manifests, single source of truth|
| CI/CD              | GitHub Actions                 | Automated testing and promotion workflow       |

---

## 🏗️ Architecture

### GitOps Flow

Trunk-based development with an automated promotion workflow:

```
Git push to master
  └─▶ CI Orchestrator triggers all tests (lint, validate, security scan)
        └─▶ If all pass, automatically promotes to `stable` branch
              └─▶ ArgoCD tracks `stable`, detects drift, and applies changes
```

ArgoCD uses the **App of Apps** pattern: Ansible installs a single root `Application` from a Jinja template, and that root app points at the `bootstrap/` Helm chart. The chart renders the child Argo applications for `apps/` and `infrastructure/`.

### Cluster Topology

```
Production
  ├── k8s-cp-1  (192.168.20.111) — control plane only, tainted NoSchedule
  ├── k8s-worker-1 (192.168.20.112) — worker
  └── k8s-worker-2 (192.168.20.113) — worker

MetalLB IP pool: 192.168.41.10 - 192.168.41.250

Staging
  └── k8s-staging-1 (192.168.20.120) — single-node control plane + workloads

MetalLB IP pool: 192.168.42.10 - 192.168.42.250
```

### Secret Management

Secrets are encrypted with `sops` using an `age` key and stored as encrypted manifests in Git. ArgoCD uses the `ksops` plugin to decrypt them at runtime — no plaintext secrets ever touch the repo.

---

## 📁 Repository Structure

```
.
├── ansible/                # VM provisioning + k3s install playbooks
├── bootstrap/              # ArgoCD App of Apps Helm chart
├── apps/                   # User-facing workloads
├── infrastructure/         # Cluster-level infrastructure (Helm wrappers)
├── scripts/                # One-off jobs (e.g. data migrations)
├── flake.nix               # Nix dev shell (all CLI tools pinned)
├── k3s_version.txt         # Single source of truth for k3s version (used by Ansible + Renovate)
└── renovate.json           # Renovate bot config
```

---

## 🔁 Reprovisioning from Scratch

Full cluster rebuild order using the Ansible playbooks. Assumes Proxmox is up with a VM template at ID `299`.

Select the target environment by inventory:

```bash
cd ansible
# production
ansible-playbook -i inventory/production/hosts.ini ...

# staging
ansible-playbook -i inventory/staging/hosts.ini ...
```

Each environment has its own `group_vars` under `inventory/<env>/group_vars/`.
- Production keeps `git_branch: stable` to only deploy CI-verified code.
- Staging can set a default branch there, but you can also override it per run with `-e git_branch=<branch>`.

> 🔑 **Before you start:** Make sure the SOPS `age` private key backup is somewhere safe and accessible. Without it, all encrypted manifests in the repo are unrecoverable.

**Step 1 — Enter dev shell:**

```bash
nix develop  # or: direnv allow
```

**Step 2 — Create secrets file:**

```bash
cp ansible/secrets.example.yaml ansible/secrets.yaml
# Fill in proxmox_api_token_secret
```

**Step 3 — Provision VMs:**

```bash
cd ansible
ansible-playbook -i inventory/production/hosts.ini playbooks/kubernetes/01-provision.yaml
```

**Step 4 — Install k3s:**

```bash
ansible-playbook -i inventory/production/hosts.ini playbooks/kubernetes/02-k3s-install.yaml
# kubeconfig is saved to ./kubeconfig-production
export KUBECONFIG=$(pwd)/../kubeconfig-production
```

**Step 5 — Setup Infrastructure (SOPS/age + ArgoCD):**

```bash
ansible-playbook -i inventory/production/hosts.ini playbooks/kubernetes/03-setup-infra.yaml
```

> ⚠️ This installs ArgoCD and the `age` key for `ksops`. This must happen **before** ArgoCD starts syncing from private repos.

**Step 6 — Label Longhorn nodes:**

After ArgoCD syncs Longhorn, label each node intended to serve as a Longhorn storage node.

```bash
kubectl label node NODE_NAME node.longhorn.io/create-default-disk=true
```

**Step 7 — Confirm ArgoCD sync:**

ArgoCD will now sync everything else automatically from this repo. Done. ✅

### Staging Cluster

The staging cluster uses the same playbooks with the staging inventory.

```bash
cd ansible
ansible-playbook -i inventory/staging/hosts.ini playbooks/kubernetes/01-provision.yaml
ansible-playbook -i inventory/staging/hosts.ini playbooks/kubernetes/02-k3s-install.yaml
export KUBECONFIG=$(pwd)/../kubeconfig-staging
ansible-playbook -i inventory/staging/hosts.ini playbooks/kubernetes/03-setup-infra.yaml
```

ArgoCD tracks the `stable` branch by default (configured via `git_branch` in `inventory/staging/group_vars/all.yaml`). The bootstrap playbook injects that value into the root Argo application, which then passes it into the `bootstrap/` Helm chart as `targetRevision`.

For one-off staging tests, prefer a CLI override:

```bash
ansible-playbook -i inventory/staging/hosts.ini playbooks/kubernetes/03-setup-infra.yaml -e git_branch=feat-x
```

---

## 🔒 CI Pipeline

A central `.github/workflows/main.yaml` orchestrator evaluates path changes and dynamically triggers the appropriate reusable workflows below. If all required tests pass on `master`, the commit is automatically promoted to the `stable` branch.

| Check              | Tool                         | What it validates                             |
| ------------------ | ---------------------------- | --------------------------------------------- |
| K8s manifests      | kubeconform                  | Schema validation against k3s version         |
| API deprecations   | Pluto                        | Catches deprecated/removed k8s APIs           |
| Security misconfig | Trivy                        | IaC misconfiguration scan (CRITICAL/HIGH)     |
| Ansible            | ansible-lint                 | Ansible best practices                        |
| YAML               | yamllint                     | YAML formatting                               |
| Shell scripts      | ShellCheck                   | POSIX/bash linting                            |
| Nix                | alejandra + statix + deadnix | Nix formatting, linting, dead code            |
| Secrets            | Gitleaks                     | Prevents secret leaks (pre-commit + daily CI) |

Pre-commit hooks run `gitleaks`, `yamllint`, and `shellcheck` on every commit locally.

---

## 🛠️ Dev Environment

Uses a [Nix flake](./flake.nix) for a fully reproducible dev shell with all tools pinned:

```bash
nix develop
# or with direnv:
direnv allow
```

The `shellHook` sets up the Python venv, installs Ansible dependencies and collections, and configures `pre-commit`.

Includes: `kubectl`, `helm`, `sops`, `age`, `argocd`, `kubeconform`, `trivy`, `pluto`, `gitleaks`, `yamllint`, `shellcheck`, `kubectx`, `pre-commit`, and the full Ansible stack in a venv.
