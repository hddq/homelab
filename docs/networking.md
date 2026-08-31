# Homelab Networking

## Overview
The main network manager for the homelab is an **OpenWrt** router. It handles the core routing, firewall rules, and VLAN segmentation across the infrastructure.

## VLAN Configuration
The network is heavily segmented into several VLANs to isolate traffic and improve security.

| VLAN ID | Purpose | Description |
| :---: | :--- | :--- |
| **10** | `users` | Trusted user devices (laptops, phones, personal PCs). |
| **20** | `servers` | Bare metal servers, hypervisors, and core infrastructure nodes. |
| **40** | `lxc/docker` | Legacy LXC and Docker container workloads. |
| **41** | `k8s prod` | Kubernetes Production cluster nodes and services. |
| **42** | `k8s staging` | Kubernetes Staging cluster nodes and services. |
| **50** | `guests` | Isolated guest network for visitors. |
| **70** | `wireguard0` | Wireguard VPN clients. |

## Kubernetes Container IP Allocations

The following table tracks the static IP addresses allocated to specific Kubernetes containers/services (via Cilium LoadBalancers) in the Production cluster (VLAN 41).

| IP Address      | Namespace  | Service                | Description                 |
| --------------- | ---------- | ---------------------- | --------------------------- |
| `192.168.41.10` | `traefik`  | `infra-traefik` | Main ingress controller     |
| `192.168.41.11` | `unbound`  | `unbound-service`      | Unbound DNS server          |
| `192.168.41.12` | `monitoring` | `graphite-exporter`    | Graphite metrics exporter   |
| `192.168.41.13` | `blocky`   | `blocky`               | Blocky DNS proxy/ad-blocker |
| `192.168.41.14` | `tor`      | `tor`                  | Tor SOCKS5 proxy server     |
