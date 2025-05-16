+++
date = '2025-05-16T11:50:26-07:00'
draft = true
title = 'Deploying to the Cloud! Moving off Prem and onto OKE'
+++


Hey everyone! And welcome back. The journey to deepen my skills in software engineering and cloud-native technologies continues. Recently, I embarked on a project to redeploy my personal website, [paulojauregui.com](https://paulojauregui.com), onto an Oracle Kubernetes Engine (OKE) cluster. I was hosting it locally from my Kubernetes cluster that lives in my closet, and while fun and educative this experience was, it was not without its pitfalls. Namely, if/when I broke my internet by playing around with my server, my site would become unavailable. To accomplish this, we would continue using a complete GitOps approach with Argo CD, ensuring automated SSL with Cert-Manager, and navigating the real-world challenges that come with it. I'm excited to share the process, the hurdles, and the "aha!" moments.

## The Foundation: A GitOps-Ready OKE Cluster

Before deploying the website itself, I had already set up a solid foundation on OKE:

* **OKE Cluster:** Two Always Free Ampere A1 `arm64` worker nodes.
* **Argo CD:** Installed and configured, connected to my private GitOps repository. We're using an "App of Apps" pattern here.
* **Cert-Manager:** Deployed via Argo CD, with `ClusterIssuer` resources ready for Let's Encrypt (using Cloudflare for DNS01 challenges).
* **Nginx Ingress Controller:** Also deployed via Argo CD, configured for `arm64` nodes and integrated with an OCI Load Balancer, providing an external IP.

With this robust ingress and certificate management stack in place, all managed declaratively through Git, I was ready to deploy my actual website.

## Deploying My Website: The GitOps Way

The core idea of GitOps is that Git is the single source of truth. All configurations, including Kubernetes manifests for my website, would live in my Git repository. Argo CD would then ensure that the live state of my cluster matches what is defined in Git.

### 1. Crafting the Kubernetes Blueprints

I started by creating the necessary Kubernetes manifest files in a new path within my GitOps repository: `oke/apps/paulojauregui-com/`.

**a. Namespace (`00-namespace.yaml`)**

First, a dedicated namespace to keep all my website's resources organized:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: paulojauregui-com
  labels:
    app.kubernetes.io/name: paulojauregui-com
    app.kubernetes.io/instance: paulojauregui-com
```

**b. Deployment (`01-deployment.yaml`)**

This defines how my website's Docker container (a Hugo site served by Nginx) should run. Key aspects:

* Uses my public Docker image: `ghcr.io/howdiggy/paulojauregui-com:latest`.
* Runs 2 replicas for availability.
* Specifies `containerPort: 80`.
* Includes resource requests and limits for CPU and memory.
* Crucially, a `nodeSelector` to ensure pods run on my `arm64` OKE nodes.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paulojauregui-com-deployment
  namespace: paulojauregui-com
  labels:
    app: paulojauregui-com
spec:
  replicas: 2
  selector:
    matchLabels:
      app: paulojauregui-com
  template:
    metadata:
      labels:
        app: paulojauregui-com
    spec:
      containers:
      - name: paulojauregui-com-container
        image: ghcr.io/howdiggy/paulojauregui-com:latest
        imagePullPolicy: Always # Important for :latest tag
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "256Mi" 
            cpu: "450m"   
      nodeSelector:
        kubernetes.io/arch: "arm64"
```

**c. Service (`02-service.yaml`)**

A `ClusterIP` service to provide a stable internal IP address for my website pods. The Nginx Ingress controller will route traffic to this service.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: paulojauregui-com-service
  namespace: paulojauregui-com
  labels:
    app: paulojauregui-com
spec:
  type: ClusterIP
  selector:
    app: paulojauregui-com # Must match pod labels
  ports:
  - protocol: TCP
    port: 80       # Service port
    targetPort: 80 # Port on the pods
```

**d. Ingress (`03-ingress.yaml`)**

This is the gateway for external traffic. It tells the Nginx Ingress Controller how to route requests for `paulojauregui.com` and instructs Cert-Manager to handle SSL.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: paulojauregui-com-ingress # Changed from paulo-website-ingress
  namespace: paulojauregui-com   # In the paulojauregui-com namespace
  annotations:
    kubernetes.io/ingress.class: "nginx" # Specifies to use the Nginx Ingress Controller
    cert-manager.io/cluster-issuer: "letsencrypt-prod" # Tells Cert-Manager to use your production issuer
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true" # Enforces HTTPS
    # Optional: If you want to enable access logs for this specific ingress (they are often enabled globally on the controller)
    # nginx.ingress.kubernetes.io/enable-access-log: "true"
spec:
  tls: # TLS configuration for HTTPS
  - hosts:
    - paulojauregui.com # Your domain
    - www.paulojauregui.com # Originally forgot to include this host and www.paulojauregui.com would not resolve
    secretName: paulojauregui-com-tls # Cert-Manager will create/use a secret with this name to store the certificate
  rules:
  - host: paulojauregui.com # Your domain
    http:
      paths:
      - path: / # Route all traffic for this host
        pathType: Prefix # Matches based on URL prefix
        backend:
          service:
            name: paulojauregui-com-service # The Service we created in 02-service.yaml
            port:
              number: 80 # The port on the Service to forward traffic to

  - host: www.paulojauregui.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: paulojauregui-com-service
            port:
              number: 80

```

### 2. Telling Argo CD About My Site

With the application manifests defined, I needed to tell Argo CD to manage them. I created a new "parent" Argo CD Application manifest. I stored this in `k8s-gitops/argo-apps-management/paulojauregui-com-parent-app.yaml` (keeping parent apps separate from the app manifests they manage).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: paulojauregui-com
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:HowDiggy/k8s-gitops.git # My GitOps repo
    path: oke/apps/paulojauregui-com                # Path to the website's manifests
    targetRevision: HEAD
  destination:
    server: [https://kubernetes.default.svc](https://kubernetes.default.svc)
    namespace: paulojauregui-com # Deploy into our website's namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - ApplyOutOfSyncOnly=true
```
This tells Argo CD to watch the specified path in my Git repo and automatically sync any changes to my OKE cluster, creating the namespace if needed.

## The Journey to "Live": Troubleshooting Adventures

With all the YAML committed to Git, I applied the `paulojauregui-com-parent-app.yaml` using `kubectl`. Argo CD picked it up, and the deployment process began... along with the inevitable troubleshooting!

**1. The ARM64 Docker Challenge (`ImagePullBackOff`)**

My OKE nodes are `arm64`, and the first hurdle was an `ImagePullBackOff` error. The logs showed: `no Image found in manifest list for architecture arm64`. My Hugo site is served by Nginx, defined in this Dockerfile:

```dockerfile
# Build stage
FROM ghcr.io/gohugoio/hugo:latest AS builder
WORKDIR /src
COPY . .
USER root # To ensure permissions are fine for Hugo build
RUN hugo --config hugo.toml --minify

# Production stage
FROM nginx:1.23-alpine
COPY --from=builder /src/public /usr/share/nginx/html
RUN rm /etc/nginx/conf.d/default.conf # Remove default Nginx config
COPY nginx.conf /etc/nginx/conf.d/   # Add my custom config
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```
While the base images (`hugo` and `nginx:alpine`) are multi-arch, my initial `docker build` on an amd64 machine only pushed an amd64 layer. The fix was to use `docker buildx` to build and push a multi-arch image:
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t ghcr.io/howdiggy/paulojauregui-com:latest --push .
```

**2. GHCR Push Permissions (`403 Forbidden`)**

The `buildx` command then failed with a `403 Forbidden` error from GHCR. This was an authentication issue. I needed to log in to GHCR using a GitHub Personal Access Token (PAT) with `write:packages` scope:
```bash
docker login ghcr.io -u HowDiggy -p YOUR_PAT_HERE
```
After this, the multi-arch image pushed successfully!

**3. The Redirect Loop Menace (`ERR_TOO_MANY_REDIRECTS`)**

With the image pulled and pods running, I hit the next wall: `ERR_TOO_MANY_REDIRECTS`. The Nginx Ingress logs showed it was issuing `308` redirects. This classic issue happens when Cloudflare's SSL/TLS mode is "Flexible." In this mode, Cloudflare connects to the origin (my Nginx Ingress) over HTTP. My Ingress, configured with `force-ssl-redirect: "true"`, would then redirect the HTTP request back to HTTPS, creating a loop.

The fix was to change the SSL/TLS mode in Cloudflare for `paulojauregui.com` to **"Full (Strict)"**. This ensures Cloudflare connects to my origin over HTTPS.

**4. The Final SSL Hurdle (Cloudflare Error 526 - Invalid SSL Certificate)**

Changing to "Full (Strict)" resolved the redirect loop but led to a Cloudflare Error 526, indicating an invalid SSL certificate at the origin. I checked my `Certificate` resource (`kubectl describe certificate paulojauregui-com-tls -n paulojauregui-com`), and it showed `Status: True, Reason: Ready`. Cert-Manager had successfully issued the certificate!

The problem was that the Nginx Ingress controller hadn't yet loaded this newly issued certificate. It was likely still presenting its default self-signed certificate for my domain when Cloudflare first tried to validate it.

A quick rollout restart of the Nginx Ingress controller pods forced them to re-read all Ingresses and their associated TLS secrets:
```bash
kubectl rollout restart deployment nginx-ingress-ingress-nginx-controller -n ingress-nginx
```

## Flipping the DNS Switch

With the Ingress controller now using the correct Let's Encrypt certificate, the final step was to update my DNS records in Cloudflare. I deleted my old CNAME records (used for a previous local setup) and added:

* An `A` record for `paulojauregui.com` (or `@`) pointing to my Load Balancer IP: `165.1.79.244`.
* A `CNAME` record for `www` pointing to `paulojauregui.com`.

Both were set to "Proxied" (orange cloud) in Cloudflare.

## Success! And What I Learned

After waiting a few moments for DNS to propagate and the Ingress controller to settle... **it worked!**

Okay, okay, ... this is what we all hope will be the case. Some of the troubleshooting sequence above actually came after flipping the switch. This is often how one might _plan_ a deployment, but the reality of debugging often involves iterating and discovering issues after initial connections are made. Nonetheless! Seeing the site come up for the first time is truly a great feeling.

`https://paulojauregui.com` was live, serving my Hugo site from OKE, fully HTTPS secured, and all managed through Git.

This project was an incredible learning experience. It reinforced the power of GitOps for declarative configuration and automation. More importantly, the troubleshooting journey was invaluable. Working through image compatibility, registry authentication, SSL/TLS intricacies between Cloudflare and Kubernetes, and the behavior of Ingress controllers provided deep insights that go beyond textbook knowledge. These are the challenges that build real-world engineering skills.

Key takeaways for me:
* **Multi-arch images are crucial** when dealing with diverse hardware like ARM64.
* **Understanding the full flow of a request** from the browser, through Cloudflare, to the Ingress, Service, and finally the Pod, is essential for debugging.
* **SSL/TLS configurations** have many layers, and each needs to be correct.
* **Patience and systematic troubleshooting** (checking logs at each stage, describing resources) are your best friends.

## What's Next?

This is a solid foundation, but there's always more to learn and improve! I'm thinking about:
* Implementing monitoring with Prometheus and Grafana, or once again setting up my ELK stack
* Customizing this Hugo template and making it a bit more unique

Thanks for reading about my deployment journey! I hope this detailed walkthrough is helpful to others venturing into similar setups. It's been a challenging but incredibly rewarding project.

## Say hello!

If you would like to reach out and chat, or if you know anyone who is looking to hire an awesome team member, I encourage you to find me on [LinkedIn](https://www.linkedin.com/in/paulo-jauregui/)!

