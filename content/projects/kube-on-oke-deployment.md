+++
date = '2025-05-10T12:15:48-07:00'
draft = true
title = 'From Zero to OKE: My Adventure Building a Free Kubernetes Cluster on Oracle Cloud (and the Lessons Learned!)'
+++

As someone passionate about diving deeper into cloud-native technologies and aiming for a career pivot into software or machine learning engineering, getting hands-on experience with Kubernetes in a real cloud environment was high on my list. The challenge? Doing it without breaking the bank. The solution? Oracle Cloud Infrastructure's (OCI) "Always Free" tier and its Oracle Kubernetes Engine (OKE)!

In this post, I'll walk you through my journey of setting up a two-node OKE cluster, leveraging those free resources, and navigating the inevitable troubleshooting that comes with any ambitious tech project. My goal wasn't just to get a cluster running, but to understand the nuts and bolts, especially the networking, which is so crucial in the cloud.

**Why OCI and OKE for a Free Tier Kubernetes Lab?**

Oracle's Always Free tier is surprisingly generous. For Kubernetes, it offers:

- **OKE Control Plane:** Free for "Basic Clusters." This means Oracle manages the complex Kubernetes master components for you.
- **Compute Instances:** Up to 4 Arm-based Ampere A1 OCPUs and 24GB of RAM in total, which can be configured as worker nodes. I decided to go for a 2-node setup, each with 2 OCPUs and 12GB RAM for a bit of resilience and a more realistic setup.
- **Networking & Storage:** Generous allowances for block storage (200GB total for boot and block volumes), Virtual Cloud Network resources, and data transfer.

This seemed like the perfect playground to get serious Kubernetes experience.

**Phase 1: Laying the Network Foundation (The VCN)**

Before even thinking about OKE, I knew a solid Virtual Cloud Network (VCN) was essential. I decided to go with a "Custom Create" approach for OKE, which meant setting up the VCN and its components manually first. This was a fantastic learning experience in itself.

Here’s what I configured:

1. **Compartment:** I started by creating a dedicated compartment named `oke-project` to keep all my resources organized.
2. **VCN (`oke-vcn`):** The main network, to which I assigned the CIDR block `10.0.0.0/16`.
3. **Subnets (Regional):**
    - **Public Subnet (`oke-public-subnet`):** `10.0.1.0/24`. This would host the Kubernetes API endpoint and any public load balancers.
    - **Private Subnet (`oke-private-subnet`):** `10.0.2.0/24`. My worker nodes would live here for better security.
4. **Gateways:**
    - **Internet Gateway (`oke-igw`):** To provide internet access to/from the public subnet.
    - **NAT Gateway (`oke-natgw`):** To allow worker nodes in the private subnet to initiate outbound connections to the internet (e.g., for pulling container images or OS updates) without having public IPs.
    - **Service Gateway (`oke-service-gateway`):** This became crucial later! It allows resources in the VCN to access public OCI services (like OCIR, IAM) within the OCI network backbone, without traversing the public internet.
5. **Route Tables:**
    - **Default Route Table (for Public Subnet):** I added a rule `0.0.0.0/0` -> `oke-igw`.
    - **Private Route Table (`oke-private-rt`):** Associated with `oke-private-subnet`. It got two key rules:
        - `0.0.0.0/0` -> `oke-natgw`
        - "All &lt;My-Region> Services in Oracle Services Network" -> `oke-service-gateway`
6. **Security Lists:** I started with the "Default Security List for oke-vcn" for both subnets. This needed careful tuning later, as we'll see!

**Phase 2: Creating the OKE Cluster**

With the VCN ready, I moved on to OKE:

1. **Chose "Custom Create"** for maximum control.
2. **Basic Info:** Named my cluster `oke-prod-cluster`, selected my `oke-project` compartment, and a recent Kubernetes version.
3. **Network Selection:** Pointed OKE to my `oke-vcn`.
4. **API Endpoint:** Selected `oke-public-subnet`. (My first hiccup was here – I later found out I needed to explicitly edit the cluster to "Assign a public IP address to the API endpoint" as it initially came up private).
5. **Node Pool Configuration (`arm-pool1`):**
    - **Type:** Managed
    - **Subnet:** `oke-private-subnet`
    - **Shape:** `VM.Standard.A1.Flex` (Always Free eligible!)
    - **Resources per node:** 2 OCPUs, 12GB RAM
    - **Node count:** 2
    - **SSH Key:** Added my public SSH key (id_ed25519.pub).
6. **"Basic Cluster":** Critically, on the review screen, I selected the option to **"Create a Basic cluster"** to ensure the control plane remained free.

Then, I hit "Create Cluster" and waited.

**Phase 3: The Troubleshooting Gauntlet!**

This is where the real learning (and a bit of late-night head-scratching) happened!

1. **`kubectl` Access - Problem 1: Private API Endpoint**
    
    - My cluster became "Active," but when I tried to access it, the `oci ... create-kubeconfig` command from OCI included `--kube-endpoint PRIVATE`. My API endpoint, despite being in a public subnet, didn't have a public IP assigned!
    - **Solution:** I had to "Edit" the OKE cluster settings in the OCI console and explicitly check the box to "Assign a public IP address to the API endpoint."
2. **`kubectl` Access - Problem 2: `oci: executable not found`**
    
    - With the public endpoint supposedly ready, `kubectl get nodes` on my Mac failed with `exec: executable oci not found`.
    - **Solution:** The kubeconfig generated by OCI relies on the OCI Command Line Interface (CLI) for authentication. I hadn't set this up on my Mac yet! I had to:
        1. Install OCI CLI (I used Homebrew: `brew install oci-cli`).
        2. Run `oci setup config`, providing my User OCID, Tenancy OCID, and region.
        3. This generated an API key pair (`~/.oci/oci_api_key.pem` and `~/.oci/oci_api_key_public.pem`). I made sure to set a passphrase (the second time around! We'll get here) for the private key.
        4. Upload the new `oci_api_key_public.pem` to my IAM user in the OCI console, deleting any old/unused API keys.
        5. (I also learned to manage multiple kubeconfigs by saving the OKE config to a separate file like `~/.kube/config_oke` and using `export KUBECONFIG=$HOME/.kube/config:$HOME/.kube/config_oke` in my terminal to access both my local and OKE clusters).
3. **`kubectl` Access - Problem 3: API Key Passphrase Prompt (The Hang!)**
    
    - After setting up OCI CLI, `kubectl get nodes` initiated a browser-based authentication. After authorizing, my terminal hung, sometimes with a key icon.
    - **Solution:** The OCI CLI was waiting for the passphrase for my API private key! Typing that passphrase in the hung terminal allowed it to proceed. But only after realizing I had never set a passphrase and going through the process of reinitializing the credentials file with one (Step 2 above had to be revisited).
4. **`kubectl` Access - Problem 4: Network `i/o timeout`**
    
    - No more auth errors, but now `kubectl` gave an `i/o timeout` connecting to the API server's public IP.
    - **Solution:** This pointed to a Security List issue. The "Default Security List for oke-vcn" (used by `oke-public-subnet`) needed an ingress rule to allow TCP traffic on port `6443` from `0.0.0.0/0` (the internet). I added this rule.
5. **Nodes Stuck: "Updating (configuring)" & "Registered Timeout" - The Big One!**
    
    - Finally, `kubectl get nodes` connected but returned "No resources found"! In the OCI console, my worker nodes were stuck in "Updating (configuring)" with a "Kubernetes node condition: Unavailable" and a "registered timeout" error.
    - This indicated a deeper network prerequisite issue preventing nodes in the private subnet from properly bootstrapping and joining the control plane.
    - **Troubleshooting Steps & The Fix:**
        1. **Service Gateway:** I had missed this initially for the private subnet. I created a Service Gateway for my VCN, allowing access to "All &lt;My-Region> Services in Oracle Services Network." Then, I added a route rule in my `oke-private-rt` (the private subnet's route table) to direct traffic for these OCI services to the Service Gateway.
        2. **Egress Rules:** I confirmed the Egress Rules for the "Default Security List" (used by `oke-private-subnet`) were permissive (allowing All Protocols to `0.0.0.0/0`). This was already correct.
        3. **The Breakthrough - Ingress Rules for Private Subnet:** The "Default Security List" (still shared by both public and private subnets at this point) was missing a crucial _ingress_ rule for VCN-internal communication. The OKE control plane couldn't properly communicate _to_ the worker nodes.
            - **Solution:** I added an ingress rule to the "Default Security List for oke-vcn":
                - Source: `10.0.0.0/16` (my VCN CIDR)
                - IP Protocol: `All Protocols`
                - Allowing all traffic _from within the VCN itself_.
        4. **Node Reprovisioning:** After adding this VCN-internal ingress rule, I deleted one of the stuck worker nodes. OKE automatically provisioned a new one. This time, with all network prerequisites finally in place... success!

**Phase 4: Success! Two Healthy Nodes!**

The newly provisioned node came up with "Kubernetes node condition: Ready" and "Node state: Active." I deleted the other stuck node, its replacement also came up healthy, and finally, `kubectl get nodes` proudly displayed:

```
NAME                                STATUS   ROLES   AGE   VERSION
oke-cxqwiihujioa-nqkwomk4ra-...     Ready    node    12m   v1.32.1
oke-cxqwiihujioa-nqkwomk4ra-...     Ready    node    5m    v1.32.1
```

**Key Takeaways & What's Next**

This journey was longer than expected but incredibly valuable.

- **OCI Networking is Powerful but Precise:** Every component (VCN, Subnets, Route Tables, Security Lists, IGW, NATGW, Service Gateway) plays a critical role. A misconfiguration in any one can have cascading effects.
- **Troubleshooting is Learning:** Hitting these roadblocks and working through them taught me more than if everything had worked perfectly on the first try.
- **Always Free is Viable:** It's entirely possible to get a robust, multi-node Kubernetes learning environment on OCI without spending anything.

Next up for me? Deploying my personal website and blog to this shiny new OKE cluster! It's currently running on a local k3s setup, so migrating it to OKE will be the next chapter in this cloud adventure.

Thanks for reading, and I hope this detailed walkthrough helps anyone else looking to explore Kubernetes on OCI's Always Free tier!

## Say hello!

If you would like to reach out and chat, or if you know anyone who is looking to hire an awesome team member, I encourage you to find me on [LinkedIn](https://www.linkedin.com/in/paulo-jauregui/)!
