+++
date = '2025-05-01'
draft = false
title = 'Building and Hosting a Secure Personal Website with Hugo, K3s, and Cloudflare Tunnels'
+++

_A complete GitOps approach to hosting your personal site securely from home_


For those of us who maintain homelab environments, one of the greatest challenges is securely exposing services to the internet without compromising our home network. In this post, I'll walk through how I set up my personal website using Hugo, hosted on a K3s Kubernetes cluster, and securely exposed to the internet via Cloudflare Tunnels — all following GitOps principles.

This setup provides several key benefits:

- **Security**: No open inbound ports on my home network
- **Automation**: Changes to my website are automatically deployed
- **Scalability**: Easy to add more services alongside the website
- **Learning**: Practical experience with DevOps tools and practices

## Architecture Overview

Here's the complete architecture we'll be implementing:

1. **Content Layer**: Hugo static site framework
2. **Containerization**: Docker images stored in GitHub Container Registry
3. **Orchestration**: K3s Kubernetes cluster (6-node setup)
4. **Continuous Deployment**: ArgoCD for GitOps
5. **Secure Access**: Cloudflare Tunnels

## Prerequisites

For this tutorial, I'm assuming you already have:

- A registered domain (I'm using paulojauregui.com)
- A Cloudflare account with your domain configured
- A running K3s cluster (I have 3 control plane and 3 worker nodes)
- ArgoCD installed on your cluster
- A GitHub account

## Part 1: Setting Up the Hugo Website

### Creating the Hugo Site Structure

First, I set up a basic Hugo site with the Ananke theme:

```bash
# Clone your GitHub repository
git clone https://github.com/yourusername/yoursite.git
cd yoursite

# Initialize Hugo site
hugo new site . --force
git submodule add https://github.com/theNewDynamic/gohugo-theme-ananke themes/ananke
echo 'theme = "ananke"' >> hugo.toml
```

I organized my content with:

- `content/posts/` for blog posts
- `content/projects/` for project descriptions
- `content/about.md` for my about page

### Containerizing with Docker

Create a Dockerfile in the repository root:

```dockerfile
# Build stage. Consider pinning to a specific Hugo version for stability
FROM ghcr.io/gohugoio/hugo:latest AS builder

# Set working directory
WORKDIR /src

# Copy source files
COPY . .

# Switch to root for build permissions if needed
USER root

# Build the website
RUN hugo --config hugo.toml --minify

# Production stage
FROM nginx:1.23-alpine

# Copy the built site from the builder stage
COPY --from=builder /src/public /usr/share/nginx/html

# Copy custom nginx config
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/

# Expose port 80
EXPOSE 80

# Run nginx
CMD ["nginx", "-g", "daemon off;"]
```

And a custom Nginx configuration (nginx.conf):

```nginx
server {
    listen       80;
    server_name  localhost;

    # Enable gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 10240;
    gzip_proxied expired no-cache no-store private auth;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml;
    gzip_disable "MSIE [1-6]\.";

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
        try_files $uri $uri/ =404;

        # Set caching headers for static assets
        location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
            expires 30d;
            add_header Cache-Control "public, no-transform";
        }
    }

    # Error pages
    error_page   500 502 503 504  /50x.html;
    location = /50x.html {
        root   /usr/share/nginx/html;
    }
}
```

### Setting Up GitHub Actions for CI/CD

Create `.github/workflows/build-deploy.yml`:

```yaml
name: Build and Deploy

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
        with:
          submodules: recursive

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          tags: |
            ghcr.io/yourusername/yoursite:latest
            ghcr.io/yourusername/yoursite:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Update deployment manifest
        if: github.event_name != 'pull_request'
        run: |
          echo "Updating image tag in GitOps repository"
          git clone https://x-access-token:${{ secrets.GIT_TOKEN }}@github.com/yourusername/k8s-gitops.git
          cd k8s-gitops
          
          # Ensure the directory exists
          mkdir -p websites/yoursite
          
          # Update the deployment.yaml with the new image tag
          if [ -f websites/yoursite/deployment.yaml ]; then
            sed -i "s|image: ghcr.io/yourusername/yoursite:.*|image: ghcr.io/yourusername/yoursite:${{ github.sha }}|g" websites/yoursite/deployment.yaml
          else
            echo "Creating deployment files..."
          fi
          
          # Set up git config
          git config --global user.name "GitHub Actions"
          git config --global user.email "actions@github.com"
          
          # Commit and push changes
          git add websites/yoursite/
          git commit -m "Update yoursite image to ${{ github.sha }}" || echo "No changes to commit"
          git push
```

Note: Make sure to create a `GIT_TOKEN` secret in your GitHub repository with permissions to update your GitOps repository.

## Part 2: Kubernetes Configuration

### Creating Kubernetes Manifests

In my GitOps repository, I created the following manifests under `websites/yoursite/`:

**namespace.yaml**:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: websites
```

**deployment.yaml**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: yoursite
  namespace: websites
  labels:
    app: yoursite
spec:
  replicas: 2
  selector:
    matchLabels:
      app: yoursite
  template:
    metadata:
      labels:
        app: yoursite
    spec:
      containers:
      - name: yoursite
        image: ghcr.io/yourusername/yoursite:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 20
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
```

**service.yaml**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: yoursite
  namespace: websites
spec:
  selector:
    app: yoursite
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
  type: ClusterIP
```

**kustomization.yaml**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - deployment.yaml
  - service.yaml
```

### Configuring ArgoCD

Create an ArgoCD Application manifest:

```yaml
# argocd/applications/yoursite.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: yoursite
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourusername/k8s-gitops.git
    targetRevision: main
    path: websites/yoursite
  destination:
    server: https://kubernetes.default.svc
    namespace: websites
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Part 3: Setting Up Cloudflare Tunnels

The most critical part of this setup is the Cloudflare Tunnel, which allows secure access to our website without exposing our home network to the internet.

### Creating a Cloudflare Tunnel

First, install the `cloudflared` CLI tool:

```bash
# For macOS
brew install cloudflared

# For Ubuntu/Debian
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
```

Authenticate with Cloudflare:

```bash
cloudflared tunnel login
```

Create a new tunnel:

```bash
cloudflared tunnel create mysite-tunnel
```

Configure DNS routes for your domain:

```bash
cloudflared tunnel route dns mysite-tunnel yourdomain.com
cloudflared tunnel route dns mysite-tunnel www.yourdomain.com
```

### Deploying the Tunnel in Kubernetes

First, let's create manifests for the Cloudflare Tunnel in our GitOps repository:

**namespace.yaml**:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cloudflare
```

**configmap.yaml**:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflare-tunnel-config
  namespace: cloudflare
data:
  config.yaml: |
    tunnel: <YOUR_TUNNEL_ID>
    credentials-file: /etc/cloudflared/credentials.json
    ingress:
      - hostname: yourdomain.com
        service: http://yoursite.websites.svc.cluster.local:80
      - hostname: www.yourdomain.com
        service: http://yoursite.websites.svc.cluster.local:80
      - service: http_status:404
```

**deployment.yaml**:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflare
spec:
  selector:
    matchLabels:
      app: cloudflared
  replicas: 2
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:latest
          args:
            - tunnel
            - --config
            - /etc/cloudflared/config.yaml
            - run
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            failureThreshold: 1
            initialDelaySeconds: 10
            periodSeconds: 10
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared/config.yaml
              subPath: config.yaml
            - name: credentials
              mountPath: /etc/cloudflared/credentials.json
              subPath: credentials.json
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "200m"
      volumes:
        - name: config
          configMap:
            name: cloudflare-tunnel-config
        - name: credentials
          secret:
            secretName: cloudflare-tunnel-credentials
```

**kustomization.yaml**:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - configmap.yaml
  - deployment.yaml
```

For the tunnel credentials, create a secret:

```bash
# Get your tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep mysite-tunnel | awk '{print $1}')

# Copy credentials to your control node
scp ~/.cloudflared/${TUNNEL_ID}.json user@controlnode:~/.cloudflared/

# Create the secret
kubectl create secret generic cloudflare-tunnel-credentials -n cloudflare --from-file=credentials.json=~/.cloudflared/${TUNNEL_ID}.json
```

Finally, create an ArgoCD Application for the tunnel:

```yaml
# argocd/applications/cloudflare-tunnel.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflare-tunnel
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourusername/k8s-gitops.git
    targetRevision: main
    path: infrastructure/cloudflare-tunnel
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudflare
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## The Complete GitOps Workflow

With everything set up, the workflow looks like this:

1. **Content Creation**:
    
    - Write content for my Hugo website
    - Commit and push changes to GitHub
2. **Automated Build and Deploy**:
    
    - GitHub Actions automatically builds a new Docker image
    - The image is pushed to GitHub Container Registry
    - The deployment manifest in the GitOps repo is updated with the new image tag
3. **Infrastructure Synchronization**:
    
    - ArgoCD detects changes in the GitOps repository
    - Changes are automatically applied to my Kubernetes cluster
    - My website is updated with the new content
4. **Secure External Access**:
    
    - Cloudflare Tunnel provides secure external access
    - Traffic is routed through Cloudflare's global network
    - My home network remains secure without exposed ports

## Troubleshooting Common Issues

During my setup, I encountered several issues. Here are the solutions:

### Docker Image Build Issues

If you see errors about Hugo version compatibility with your theme, update the Dockerfile to use a specific Hugo version that works with your theme:

```dockerfile
FROM ghcr.io/gohugoio/hugo:0.111.3-ext AS builder
```

### ArgoCD Syncing Issues

If your ArgoCD applications aren't syncing properly, verify that:

- All referenced files in kustomization.yaml exist
- The paths in your ArgoCD applications are correct
- You have proper access permissions for Git repositories

### Cloudflare Tunnel Connection Issues

If you see "Application error 0x0" in your Cloudflare Tunnel logs:

1. Check if your tunnel credentials are correctly mounted
2. Verify the tunnel ID in the ConfigMap matches your actual tunnel ID
3. Consider creating a new tunnel and using its credentials

## Security Benefits

This setup provides significant security advantages:

1. **No Port Forwarding Required**:
    
    - My home network firewall doesn't need any open inbound ports
    - All connections are outbound-only from my K3s cluster
2. **DDoS Protection**:
    
    - Cloudflare's network shields my infrastructure from attacks
    - Traffic is filtered and proxied through Cloudflare's edge
3. **IP Address Privacy**:
    
    - My home IP address is never exposed in DNS records
    - All traffic appears to come from Cloudflare's network
4. **Encrypted Traffic**:
    
    - All traffic is encrypted between visitors, Cloudflare, and my cluster
    - Automatic HTTPS for my website

## Conclusion

This setup demonstrates how modern cloud-native tools can be adapted for homelab environments. By leveraging Kubernetes, GitOps, and Cloudflare Tunnels, I've created a secure, automated deployment pipeline for my personal website that follows industry best practices.

The entire stack uses free or low-cost components, making it accessible for personal projects while providing enterprise-grade security and automation. Plus, this architecture can easily scale to host additional services beyond just a website.

What started as a simple personal website project has become a fantastic learning experience in cloud-native technologies and DevOps practices—all while keeping my home network secure.

---

_If you would like to use any of this code for you own project, be sure to replace placeholders with your actual values!_