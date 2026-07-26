<div align="center">

# Homelab

Personal homelab managed through Infrastructure as Code — built to minimize manual server changes and keep Git as the source of truth.

[![CI](https://github.com/hddq/homelab/actions/workflows/main.yaml/badge.svg)](https://github.com/hddq/homelab/actions/workflows/main.yaml)

</div>

## Stack

| Area | Technology | Role |
| --- | --- | --- |
| Hypervisor | Proxmox VE | Hosts local virtual machines, including Talos nodes. |
| Network | OpenWrt + FRR | Routing, VLAN segmentation, firewalling, and BGP peers for MetalLB. |
| Storage | TrueNAS | Network-attached storage for shared data, storage services, and backups. |
| Public DNS | Cloudflare | DNS records, wildcard ingress records, and DNS-01 certificate support. |
| External compute | Oracle Cloud + NixOS | `vps0`, including WireGuard, DNS, and corosync qdevice services. |
| Infrastructure IaC | OpenTofu/Terraform | Provisions Proxmox, Cloudflare, and Oracle Cloud resources. |
| Host automation | Ansible | Automates infrastructure configuration and operational services. |
| Secrets | SOPS + age | Encrypts repository secrets at rest. |
| Developer environment | Nix flake | Provides the reproducible local toolchain. |
| Automation | GitHub Actions + Renovate | Validates changes, promotes releases, and opens dependency updates. |

## Kubernetes Stack

Two independent clusters, `homelab-production` and `homelab-staging`, run
vanilla Kubernetes on Talos Linux. Talos contains only the host configuration
needed to start Kubernetes; cluster services are installed through Helm charts
and regular manifests under `kubernetes/clusters/homelab/`.

| Area | Technology | Role |
| --- | --- | --- |
| Node OS | Talos Linux | Immutable Kubernetes host OS, rendered with Talhelper. |
| Provisioning | OpenTofu/Terraform | Creates the Proxmox VMs and their disks. |
| GitOps | Argo CD | Reconciles the cluster from this repository using App of Apps. |
| Packaging | Helm | Wraps infrastructure charts and the bootstrap chart. |
| Load balancing | MetalLB | Announces service addresses through BGP. |
| Ingress | Traefik | Handles ingress traffic and TLS termination. |
| Certificates | cert-manager + Cloudflare | Issues certificates through DNS-01. |
| Storage | OpenEBS LocalPV Hostpath | Provides node-local persistent volumes at `/var/openebs/local`. |
| Backups | K8up | Backs up persistent volumes to TrueNAS storage. |
| Observability | VictoriaMetrics, Grafana, Alertmanager, vmagent, vmalert | Collects, stores, visualizes, and alerts on metrics. |


### Cluster Topology

| Environment | Nodes | Kubernetes endpoint |
| --- | --- | --- |
| Production | `k8s-prod-cp-1` (control plane + workloads), `k8s-prod-worker-1` (worker) | `192.168.20.100:6443` |
| Staging | `k8s-staging-1` (control plane + workloads) | `192.168.20.120:6443` |

## Architecture

```text
Oracle Cloud (vps0: DNS / qdevice)
       |
   WireGuard
       |
OpenWrt + FRR ---- BGP ---- MetalLB ---- Kubernetes Services
       |                             |
       |                             +---- Traefik ---- Cloudflare DNS
       |
       +---- Proxmox VE
              ├---- Talos production and staging VMs
              └---- TrueNAS
```

GitOps promotion follows a trunk-based model:

```text
master -> GitHub Actions validation -> stable -> Argo CD reconciliation
```

The root Argo CD application renders the bootstrap chart, which creates the
infrastructure and application `Application` resources for the selected
environment.

## Repository Layout

```text
.
├── ansible/                         # Infrastructure configuration and operational playbooks
├── docs/                            # Network and operational documentation
├── kubernetes/
│   ├── clusters/homelab/
│   │   ├── apps/                    # Workloads managed by Argo CD
│   │   ├── bootstrap/               # Root App of Apps chart
│   │   └── infra/                   # Cluster services and Helm wrappers
│   └── policies/                    # Kyverno policies
├── nix/vps0/                        # NixOS configuration for the Oracle Cloud VPS
├── scripts/                         # Bootstrap, validation, migration, and administration tools
├── shared/dns/                      # Shared Blocky and Unbound configuration
├── talos/
│   ├── common.yaml                  # Shared Talhelper configuration
│   ├── environments/                # Per-cluster topology, environment values, and SOPS secrets
│   └── versions.yaml                # Talos and Kubernetes version source of truth
├── terraform/
│   ├── cloudflare/                  # DNS and email-routing resources
│   ├── oracle-cloud/                # VPS infrastructure
│   └── proxmox/                     # Proxmox infrastructure
├── flake.nix                        # Development shell
└── renovate.json                    # Dependency update configuration
```

## Operating the Platform

### Development Environment

```bash
nix develop
```

The development shell provides Talos, Kubernetes, OpenTofu, Helm, SOPS,
Ansible, and validation tooling. Its shell hook also prepares the Ansible
environment and installs pre-commit hooks.

### Talos Configuration

Talhelper renders each environment by merging `talos/common.yaml` with its
environment definition. `talos/versions.yaml` is the shared source for Talos
and Kubernetes versions and is consumed by both Talos and Terraform.

```bash
bash scripts/talos/render.sh staging
bash scripts/talos/render.sh production
```

Rendered machine configurations are written to `talos/generated/<environment>/`
and are intentionally not committed. Each environment has a separate
SOPS-encrypted `talsecret.yaml`.

### Provisioning and Bootstrap

1. Apply the relevant OpenTofu configuration in `terraform/proxmox/` to create
   or update Talos VMs.
2. Render Talos configuration, apply it to the nodes, and bootstrap the control
   plane with `talosctl`.
3. Obtain the cluster kubeconfig, then run the Argo CD bootstrap script:

```bash
bash scripts/kubernetes/bootstrap-cluster.sh production stable kubeconfig-production
```

Pass `staging` and the appropriate kubeconfig for the staging cluster. The
bootstrap script installs Argo CD, adds the SOPS age key and repository
credential, then applies the root application.

### External VPS

`terraform/oracle-cloud/` creates the Oracle Cloud instance and runs
`nixos-anywhere` with the `nix/vps0` flake. The VPS SOPS age key must be present
at `/var/lib/sops-nix/key.txt` for NixOS-managed secrets.

After the initial VPS provision, install its dedicated age identity:

```bash
ssh vps0 'sudo mkdir /var/lib/sops-nix && sudo chown $(whoami) /var/lib/sops-nix'
scp vps0.key vps0:/var/lib/sops-nix/key.txt
ssh vps0 'sudo chmod 600 /var/lib/sops-nix/key.txt && sudo chown root:root /var/lib/sops-nix/key.txt'
```

## Secrets

SOPS-encrypted files remain in Git; age private keys do not. The local SOPS key
is required to render Talos configs, apply Terraform configurations that use
encrypted provider credentials, and bootstrap Argo CD. Keep recovery copies of
the age key outside the homelab.

## CI and Dependency Updates

GitHub Actions runs focused workflows based on changed paths. These cover
Talos rendering and validation, OpenTofu formatting and validation, Kubernetes
rendering and schema validation, Helm linting, Pluto API deprecation checks,
Trivy, Ansible, Nix, shell, Python, YAML, and secret scanning.

Renovate tracks chart, image, action, Talos, Kubernetes, and other dependency
versions. Talos and Kubernetes updates start in `talos/versions.yaml`.
