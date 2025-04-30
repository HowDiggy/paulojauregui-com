---
title: "K3s Homelab Cluster"
date: 2025-04-25
draft: true
---

A 6-node K3s cluster managed with GitOps principles using ArgoCD.

## Architecture

- 3 control plane nodes (also running etcd)
- 3 worker nodes
- Traefik ingress controller
- ArgoCD for GitOps deployment
- ELK stack for observability (ElasticSearch, Logstash, and Kibana)

## Technologies Used

- Kubernetes (K3s)
- Ansible for automation
- Kustomize for configuration
- ArgoCD for continuous deployment
- Proxmox as the hypervisor running this on Virtual Machines
