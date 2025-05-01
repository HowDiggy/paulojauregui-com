+++
date = '2025-04-29'
draft = false
title = 'Setting Up PostgreSQL with Synology iSCSI Storage in a K3s Cluster'
+++

_Taking care of Persistent Volumes and Persistent Volume Claims_


In my ongoing journey to build a production-grade homelab environment, I recently tackled one of the most critical challenges of running stateful applications in Kubernetes: reliable persistent storage. In this post, I'll walk through how I connected my K3s cluster to my Synology NAS via iSCSI to provide robust storage for a PostgreSQL database.

This solution combines the power of Kubernetes with the reliability of dedicated storage hardware, providing a solid foundation for running databases and other stateful applications in a home environment.

## My Environment

First, let me share the components involved in this setup:

- **k3s Cluster**: A 6-node cluster (3 control plane, 3 workers) running on Ubuntu
- **Synology NAS**: My central storage server (running at 192.168.1.24)
- **Management**: Ansible for configuration management and GitOps methodology with ArgoCD

## The Challenge

While k3s includes the local-path storage provider out of the box, it doesn't provide the reliability and performance needed for database workloads. When a pod using local-path storage gets rescheduled to a different node, it loses access to its data. Clearly not ideal for a database!

I needed a solution that would:

1. Provide consistent, high-performance storage for PostgreSQL
2. Allow data to persist regardless of which node the database runs on
3. Leverage my existing Synology NAS investment

## Exploring Storage Options

I considered several options for my storage needs:

1. **External VM with PostgreSQL**: Simple but isolated from the Kubernetes ecosystem
2. **Synology NFS**: Easy to set up but not ideal for database performance
3. **Synology iSCSI**: Better performance for databases with direct block storage
4. **Longhorn or Rook+Ceph**: Kubernetes-native but adds complexity and resource overhead

After weighing the options, I decided on **Synology iSCSI** for its combination of performance, simplicity, and integration with my existing hardware.

## Implementation: The Hard Way

Rather than using a storage operator, I decided to implement a direct iSCSI connection for more control and understanding of the underlying mechanisms. Here's my step-by-step process:

### 1. Setting Up iSCSI on Synology

First, I configured my Synology NAS:

- Created an iSCSI target named "k3s-postgres-target"
- Created a thin-provisioned LUN (110GB)
- Set up CHAP authentication for security

### 2. Configuring iSCSI Initiators on k3s Nodes

Next, I created an Ansible playbook to configure all my k3s nodes:

```yaml
# install_iscsi.yml
- name: Install iSCSI packages on Debian/Ubuntu
  apt:
    name:
      - open-iscsi
      - multipath-tools
    state: present
    update_cache: yes

- name: Enable and start iSCSI service
  systemd:
    name: "{{ item }}"
    state: started
    enabled: yes
  loop:
    - iscsid
    - open-iscsi

- name: Configure CHAP authentication
  lineinfile:
    path: /etc/iscsi/iscsid.conf
    regexp: "{{ item.regexp }}"
    line: "{{ item.line }}"
  loop:
    - { regexp: '^node.session.auth.authmethod', line: 'node.session.auth.authmethod = CHAP' }
    - { regexp: '^node.session.auth.username', line: 'node.session.auth.username = jaupau' }
    - { regexp: '^node.session.auth.password', line: 'node.session.auth.password = b!ockyB10ck8lok' }
  notify: restart iscsid
```

This playbook installed the necessary packages and configured CHAP authentication to match my Synology settings.

### 3. Creating Kubernetes Resources

I created PersistentVolume and PersistentVolumeClaim resources to make the iSCSI storage available to Kubernetes:

```yaml
# postgres-pv-new.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: postgres-data-pv-new
spec:
  capacity:
    storage: 110Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  iscsi:
    targetPortal: 192.168.1.24:3260
    iqn: iqn.2000-01.com.synology:Nashoba.Target-1.c0dc8a8f5ec
    lun: 1  # Important! This must match the LUN ID on your Synology
    fsType: ext4
    readOnly: false
    chapAuthSession: true
    secretRef:
      name: chap-secret
```

```yaml
# postgres-pvc-new.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data-new
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 110Gi
  volumeName: postgres-data-pv-new
  storageClassName: ""
```

```yaml
# chap-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: chap-secret
type: Opaque
data:
  node.session.auth.username: amF1cGF1  # base64 encoded "jaupau"
  node.session.auth.password: YiFvY2t5QjEwY2s4bG9r  # base64 encoded
```

### 4. Deploying PostgreSQL

Finally, I created a PostgreSQL deployment using this storage:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:14
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secrets
                  key: postgresql-password
            - name: POSTGRES_DB
              value: myapplication
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              memory: "512Mi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "2"
      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-data-new
```

## Troubleshooting Adventures

The path to success wasn't without some valuable learning experiences (read: troubleshooting). Here are the key issues I encountered and how I resolved them:

### 1. Duplicate IQN Issue

Initially, all my nodes had identical iSCSI initiator names (IQNs) because they were created from the same template (who wants to provision six different virtual machines through a GUI? One day I will set up cloudinit and terraform!). This caused connection conflicts.

**Solution:** Create unique IQNs for each node based on their hostname and MAC address.

### 2. CSI Driver Challenges

I initially tried to use the iSCSI CSI driver, but ran into image pull issues as the required container image wasn't available anymore.

**Solution:** Switch to a direct iSCSI approach without the CSI driver by manually defining the PV/PVC pair.

### 3. LUN Numbering Mismatch

The most subtle issue was a mismatch between the LUN number in the PersistentVolume definition (LUN 0) and the actual LUN number on my Synology (LUN 1).

**Solution:** Create a new PV/PVC pair with the correct LUN number (1).

### 4. iSCSI Connectivity

Getting the iSCSI connection properly established on each node required:

- Verifying CHAP credentials were correct
- Ensuring the iSCSI service was running
- Manually checking connection status with `iscsiadm -m session -P 3`

## Success Verification

How did I know everything was working? The logs tell the story:

```
PostgreSQL Database directory appears to contain a database; Skipping initialization
2025-03-15 03:23:20.414 UTC [1] LOG:  starting PostgreSQL 14.17 (Debian 14.17-1.pgdg120+1) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14) 12.2.0, 64-bit
2025-03-15 03:23:20.414 UTC [1] LOG:  listening on IPv4 address "0.0.0.0", port 5432
2025-03-15 03:23:20.414 UTC [1] LOG:  listening on IPv6 address "::", port 5432
2025-03-15 03:23:20.419 UTC [1] LOG:  listening on Unix socket "/var/run/postgresql/.s.PGSQL.5432"
2025-03-15 03:23:20.422 UTC [27] LOG:  database system was shut down at 2025-03-15 03:23:07 UTC
2025-03-15 03:23:20.427 UTC [1] LOG:  database system is ready to accept connections
```

The key line "PostgreSQL Database directory appears to contain a database; Skipping initialization" confirmed that my storage was properly persisting between pod restarts.

## Benefits of This Approach

This setup provides several advantages for my homelab:

1. **Data Persistence**: PostgreSQL data safely stored on my Synology NAS
2. **Performance**: Direct block storage via iSCSI instead of slower network file systems
3. **Kubernetes Integration**: Native PV/PVC approach works with all Kubernetes tools
4. **Hardware Reuse**: Leverages my existing Synology investment
5. **Security**: CHAP authentication ensures only authorized access

## Lessons Learned

This project taught me several valuable lessons about Kubernetes storage:

1. **Understanding LUN Mapping**: The relationship between storage targets, LUNs, and how they appear in the operating system
2. **Kubernetes Storage Immutability**: PersistentVolume sources can't be modified after creation
3. **Troubleshooting Skills**: Using tools like `iscsiadm` to diagnose iSCSI connections
4. **The Importance of Unique IQNs**: Each node needs its own identity when connecting to shared storage
5. **Thin vs. Thick Provisioning**: Thin provisioning worked better in my environment

## Next Steps

With PostgreSQL successfully deployed with persistent storage, I'm planning to:

1. Implement regular backups using Synology's snapshot capabilities
2. Set up database replication for better high availability
3. Create a monitoring solution for both PostgreSQL and the underlying storage
4. Explore GitOps deployment of the complete database stack

## Conclusion

Setting up PostgreSQL with Synology iSCSI storage in a k3s cluster provides a robust foundation for running stateful applications in a homelab environment. While it required more manual configuration than using a storage operator like Longhorn, the process gave me valuable insights into how Kubernetes storage works under the hood.

This approach combines the best of both worlds - enterprise-grade storage from my Synology NAS with the orchestration capabilities of Kubernetes - without requiring additional hardware or complex storage solutions.

If you're running a similar homelab setup, I highly recommend exploring iSCSI integration with your existing NAS - it provides an excellent balance of performance, reliability, and resource efficiency.

---
