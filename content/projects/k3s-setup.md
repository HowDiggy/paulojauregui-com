# Setting Up a 6-Node K3s Kubernetes Cluster with Ansible

_Posted on April 29, 2025_

## Introduction

Hello fellow homelab enthusiasts! Today I'm going to walk you through how I set up a 6-node Kubernetes cluster using K3s and Ansible. This was part of my ongoing project to build a production-grade home lab environment using GitOps methodologies with ArgoCD.

## My Cluster Setup

For this project, I'm running:

- 3 control plane nodes (k3s-cp0, k3s-cp1, k3s-cp2) that also run etcd
- 3 worker nodes (k3s-worker0, k3s-worker1, k3s-worker2)

I'm using Ansible to automate the deployment with all nodes managed in my inventory:

```yaml
all:
  children:
    control_plane:
      hosts:
        k3s-cp0:
          ansible_host: 192.168.1.30
        k3s-cp1:
          ansible_host: 192.168.1.31
        k3s-cp2:
          ansible_host: 192.168.1.32
    workers:
      hosts:
        k3s-worker0:
          ansible_host: 192.168.1.40
        k3s-worker1:
          ansible_host: 192.168.1.41
        k3s-worker2:
          ansible_host: 192.168.1.42
  vars:
    ansible_user: paulo
    ansible_ssh_private_key_file: /home/paulo/.ssh/id_rsa_k8s
    ansible_ssh_extra_args: "-o StrictHostKeyChecking=no"
```

## The Kubernetes Deployment Playbook

Creating a playbook for deploying K3s was more complex than I initially expected. Here were some key lessons learned:

### Initial Challenges

My first attempt at the Ansible playbook had several issues:

1. No proper HA configuration for the control plane nodes
2. Connection issues between nodes
3. Problems with permissions for the kubeconfig file
4. Difficulties with kubectl installation

### The Improved Playbook

After some troubleshooting, I developed a more robust playbook:

```yaml
---
# Install first control plane node
- name: Install K3s on first control plane node
  hosts: k3s-cp0
  become: yes
  tasks:
    - name: Install K3s (v1.32.2+k3s1) on first control plane
      shell: |
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.2+k3s1" sh -s - server --cluster-init
      register: k3s_install_output
      failed_when: "'error' in k3s_install_output.stderr | default('')"
      changed_when: "'already installed' not in k3s_install_output.stdout | default('')"
    
    - name: Wait for K3s API to be active on first control plane
      wait_for:
        port: 6443
        delay: 10
        timeout: 300
        state: started
    
    - name: Retrieve K3s token from first control plane
      slurp:
        src: /var/lib/rancher/k3s/server/node-token
      register: k3s_token_b64
    
    - name: Set token fact
      set_fact:
        k3s_token: "{{ k3s_token_b64['content'] | b64decode | trim }}"
        k3s_api_endpoint: "https://{{ ansible_default_ipv4.address }}:6443"

# Add additional control plane nodes
- name: Install K3s on additional control plane nodes
  hosts: k3s-cp1, k3s-cp2
  become: yes
  vars:
    k3s_token: "{{ hostvars['k3s-cp0']['k3s_token'] }}"
    k3s_api_endpoint: "{{ hostvars['k3s-cp0']['k3s_api_endpoint'] }}"
  tasks:
    - name: Install K3s on additional control plane nodes
      shell: |
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.2+k3s1" K3S_TOKEN="{{ k3s_token }}" K3S_URL="{{ k3s_api_endpoint }}" sh -s - server
      register: k3s_install_output
      failed_when: "'error' in k3s_install_output.stderr | default('')"
      changed_when: "'already installed' not in k3s_install_output.stdout | default('')"
    
    - name: Wait for K3s to be active on additional control planes
      wait_for:
        port: 6443
        delay: 10
        timeout: 300
        state: started

# Install worker nodes
- name: Install K3s on worker nodes
  hosts: k3s-worker0, k3s-worker1, k3s-worker2
  become: yes
  vars:
    k3s_token: "{{ hostvars['k3s-cp0']['k3s_token'] }}"
    k3s_api_endpoint: "{{ hostvars['k3s-cp0']['k3s_api_endpoint'] }}"
  tasks:
    - name: Install K3s on worker nodes
      shell: |
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.32.2+k3s1" K3S_TOKEN="{{ k3s_token }}" K3S_URL="{{ k3s_api_endpoint }}" sh -s - agent
      register: k3s_worker_install_output
      failed_when: "'error' in k3s_worker_install_output.stderr | default('')"
      changed_when: "'already installed' not in k3s_worker_install_output.stdout | default('')"

    - name: Wait for K3s service to be active on worker nodes
      systemd:
        name: k3s-agent
        state: started
        enabled: yes
      register: k3s_agent_status
      until: k3s_agent_status.status.ActiveState == "active"
      retries: 10
      delay: 10

# Set up kubeconfig
- name: Set up kubeconfig
  hosts: k3s-cp0
  become: yes
  vars:
    user_home: "/home/{{ ansible_user }}"
  tasks:
    - name: Create .kube directory if it doesn't exist
      file:
        path: "{{ user_home }}/.kube"
        state: directory
        owner: "{{ ansible_user }}"
        group: "{{ ansible_user }}"
        mode: 0700
      
    - name: Copy k3s.yaml and modify server URL
      shell: |
        sed "s/127.0.0.1/{{ ansible_default_ipv4.address }}/" /etc/rancher/k3s/k3s.yaml > {{ user_home }}/.kube/config
        chown {{ ansible_user }}:{{ ansible_user }} {{ user_home }}/.kube/config
        chmod 600 {{ user_home }}/.kube/config
      args:
        creates: "{{ user_home }}/.kube/config"
```

## Getting kubectl Working

One challenge that tripped me up was getting kubectl working properly. I ended up creating a symlink to the k3s binary, which already includes kubectl functionality:

```yaml
- name: Setup kubectl symlink
  hosts: k3s-cp0
  become: yes
  vars:
    user_home: "/home/paulo"
  tasks:
    - name: Create kubectl symlink
      file:
        src: /usr/local/bin/k3s
        dest: /usr/local/bin/kubectl
        state: link

    - name: Ensure .kube directory exists
      file:
        path: "{{ user_home }}/.kube"
        state: directory
        owner: "paulo"
        group: "paulo"
        mode: '0700'

    - name: Copy k3s.yaml with proper permissions and update server address
      shell: |
        sed "s/127.0.0.1/{{ ansible_default_ipv4.address }}/" /etc/rancher/k3s/k3s.yaml > {{ user_home }}/.kube/config
        chown paulo:paulo {{ user_home }}/.kube/config
        chmod 600 {{ user_home }}/.kube/config
      args:
        creates: "{{ user_home }}/.kube/config"

    - name: Set KUBECONFIG environment variable in user profile
      lineinfile:
        path: "{{ user_home }}/.bashrc"
        line: "export KUBECONFIG={{ user_home }}/.kube/config"
        state: present
```

## Setting Up kubectl on the Ansible Control Node

Since I wanted to manage my cluster from my Ansible control node (rather than SSH into k3s-cp0 every time), I created an additional playbook to:

1. Install kubectl on the control node
2. Copy the kubeconfig from k3s-cp0
3. Configure it to point to the correct IP address

The key thing I learned is the importance of using `source ~/.bashrc` after modifying environment variables, which reloads your shell's environment without requiring you to log out and log back in.

## Next Steps

With my cluster up and running, I'm now focusing on:

1. Deploying ArgoCD for GitOps-based deployments
2. Setting up my ElasticSearch, Logstash, Kibana (ELK) stack for observability
3. Implementing proper storage solutions

My ELK stack is configured as:

- Filebeat: DaemonSet to collect logs from all nodes
- Logstash: StatefulSet to receive and forward logs
- Elasticsearch: StatefulSet with persistence
- Kibana: Deployment with Service and Ingress

You can find all my configurations on GitHub at: [https://github.com/HowDiggy/k8s-gitops](https://github.com/HowDiggy/k8s-gitops)

## Key Learnings

1. **High Availability Setup**: The `--cluster-init` flag is crucial for the first control plane node
2. **Permissions Matter**: User permissions and file access are important for kubectl
3. **Variable Passing**: Using `set_fact` and `slurp` properly in Ansible makes token sharing more reliable
4. **Idempotency**: Properly designed Ansible playbooks should be able to run multiple times without breaking things that already work
5. **Environment Variables**: Understand how they work across SSH and sudo sessions