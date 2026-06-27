Here is the **complete architectural build**, covering Phases 1 through 7, written strictly in datacenter/network engineering terms. 

I have structured it as a full reference guide. For **Phases 1 & 2**, I provide the CLI logic (since you already executed them). For **Phases 3 to 7**, I provide the Console steps (as you requested visual understanding for these layers).

---

## Final Target Architecture (No RDS)

- **2 Availability Zones** (AZ-A, AZ-B)
- **VPC CIDR**: `10.0.0.0/16`
- **Public Subnets** (AZ-A: `10.0.1.0/24`, AZ-B: `10.0.2.0/24`): Host the **ALB** (ingress point) and **NAT Gateways** (egress proxy).
- **Private Subnets** (AZ-A: `10.0.11.0/24`, AZ-B: `10.0.12.0/24`): Host the **EC2 instances** (Nginx reverse proxy + Backend application). No public IPs assigned.
- **Route Tables**:
  - Public RT: `0.0.0.0/0` → Internet Gateway (IGW).
  - Private RT: `0.0.0.0/0` → NAT Gateway (in the same AZ, to avoid cross-AZ data transfer costs).

---

## Phase 1: VPC, Internet Gateway, and Subnets (The L2/L3 Foundation)

**Objective**: Establish the isolated broadcast domain (VPC), the egress point to the internet (IGW), and the physical segmentation of workloads (Public vs Private subnets).

**CLI Execution (Concepts)**:

```bash
# 1.1 Create the VPC (L3 isolated network)
aws ec2 create-vpc --cidr-block 10.0.0.0/16

# 1.2 Create Internet Gateway (L3 router to the public internet)
aws ec2 create-internet-gateway
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# 1.3 Create Subnets (L2 segments within the VPC)
# Public Subnet A (10.0.1.0/24) - AZ-A
# Public Subnet B (10.0.2.0/24) - AZ-B
# Private Subnet A (10.0.11.0/24) - AZ-A
# Private Subnet B (10.0.12.0/24) - AZ-B

# 1.4 Enable the "MapPublicIpOnLaunch" attribute ONLY for Public Subnets.
# This ensures EC2s in Private subnets never receive a public IP binding.
```

**Why this layout?** The ALB must reside in the Public Subnet so it can receive SYN packets from CloudFront's edge IPs. The compute instances reside in the Private Subnet to ensure they are unreachable from the public internet, forcing all ingress traffic to traverse the ALB.

---

## Phase 2: Route Tables and NAT Gateways (The Traffic Policers)

**Objective**: Define the L3 forwarding behavior. Public subnets route directly to the IGW. Private subnets route outbound traffic through a NAT Gateway for controlled egress.

**CLI Execution (Concepts)**:

```bash
# 2.1 Create Route Tables
# Public-RT: Associates with Public Subnets.
# Private-RT-A: Associates with Private Subnet A.
# Private-RT-B: Associates with Private Subnet B.

# 2.2 Add Routes
# Public-RT: 0.0.0.0/0 -> IGW_ID
# Private-RT-A: 0.0.0.0/0 -> NAT_GW_A (placed in Public Subnet A)
# Private-RT-B: 0.0.0.0/0 -> NAT_GW_B (placed in Public Subnet B)

# 2.3 Allocate Elastic IPs and create NAT Gateways
# NAT Gateways are provisioned in the Public Subnets. 
# They perform Source NAT (SNAT): rewriting the source IP of egress packets from 10.0.11.x to their public Elastic IP.
```

**Critical Routing Insight**: The Private Subnet's route table points to the NAT Gateway, but the NAT Gateway's ENI lives in the Public Subnet. When an EC2 instance in the Private Subnet sends a packet to `8.8.8.8`, the VPC router forwards it to the NAT GW. The NAT GW translates the source IP to its own public EIP and forwards it to the IGW. The return packet reverses this path. This provides **stateful outbound-only** internet access.

---

## Phase 3: Security Groups (The Stateful L3/L4 Firewalls)

**Objective**: Create instance-level packet filters. We will use **Security Group References** (source = SG ID) instead of CIDR blocks where possible. This decouples firewall rules from IP changes (crucial for auto-scaling).

**Console Steps**:

1. Navigate to **VPC** → **Security Groups** → **Create security group**.

**SG-1: ALB-SG** (Attached to the ALB ENI)

- **Inbound Rule 1 (Phase 6 placeholder)**: Type `HTTP` (80), Source `0.0.0.0/0`. *(We will restrict this to the CloudFront Prefix List later).*
- **Outbound Rules**: Allow All (`0.0.0.0/0`). The ALB needs to initiate TCP connections to the EC2 instances on port 80.

**SG-2: App-SG** (Attached to EC2 ENIs in Private Subnets)

- **Inbound Rule 1**: Type `HTTP` (80), Source: **Select "Custom" and paste the `sg-xxxxxxxx` ID of the ALB-SG**.
  - *Mechanism*: The VPC hypervisor resolves this SG ID to the current private IPs of the ALB's ENIs. Only packets with a source IP matching these ALB ENIs are allowed into the EC2's network stack.
- **Inbound Rule 2 (Optional)**: Type `SSH` (22), Source: `YOUR_IP/32`. (For debugging; remove in production).
- **Outbound Rules**: Allow All (`0.0.0.0/0`). This allows the EC2s to send packets to the NAT Gateway for outbound updates.

---

## Phase 4: Compute Layer (Nginx Frontend + Backend)

**Objective**: Launch EC2 instances in the Private Subnets with a bootstrap script (User Data) to install and configure the web tier.

**Console Steps**:

1. Navigate to **EC2** → **Instances** → **Launch instance**.
2. **Name**: `App-Server-A`.
3. **AMI**: Select your `devops-practice` AMI.
4. **Instance type**: `t3.micro`.
5. **Key pair**: Select an existing key (for SSH troubleshooting).
6. **Network settings**:
   - VPC: `SecureVPC`.
   - Subnet: **Private Subnet A** (`10.0.11.0/24`).
   - Auto-assign public IP: **Disable**.
   - Firewall: Select **App-SG**.
7. **Advanced details → User data**: Paste the following script. This script performs:
   - `dnf install nginx python3`: Installs the reverse proxy and runtime.
   - Writes `app.py`: A Python Flask application listening on port `5000` that returns the hostname.
   - Writes `nginx.conf`: A location block that proxies `/api/` to the Flask backend, and returns a static response for `/`.
   - Starts both services.

```bash
#!/bin/bash
dnf update -y && dnf install -y nginx python3 python3-pip
systemctl enable nginx

cat << 'EOT' > /home/ec2-user/app.py
from flask import Flask, jsonify
import socket
app = Flask(__name__)
@app.route('/')
def hello(): return f"Backend: {socket.gethostname()}"
@app.route('/health')
def health(): return jsonify({"status": "healthy"}), 200
if __name__ == '__main__': app.run(host='0.0.0.0', port=5000)
EOT
pip3 install flask
nohup python3 /home/ec2-user/app.py > /var/log/backend.log 2>&1 &

cat << 'EOT' > /etc/nginx/conf.d/app.conf
server {
    listen 80;
    location /api/ { proxy_pass http://127.0.0.1:5000/; proxy_set_header Host $host; }
    location / { return 200 'Nginx Frontend Alive\n'; add_header Content-Type text/plain; }
    location /health { return 200 'healthy\n'; add_header Content-Type text/plain; }
}
EOT
systemctl restart nginx
```

8. Repeat the exact steps for **App-Server-B**, selecting **Private Subnet B** (`10.0.12.0/24`) instead.

---

## Phase 5: ALB (L7 Reverse Proxy) and Target Group

**Objective**: Deploy the Application Load Balancer to distribute incoming HTTP requests to the EC2 instances based on health checks.

**Console Steps**:

1. Navigate to **EC2** → **Target Groups** → **Create target group**.
   - Type: `Instances`. Name: `App-TG`. Protocol: HTTP, Port: 80. VPC: `SecureVPC`.
   - Health check: Path `/health`, Interval 30s, Healthy threshold 2.
   - Register targets: Select `App-Server-A` and `App-Server-B`. Click "Include as pending below". Create.

2. Navigate to **EC2** → **Load Balancers** → **Create load balancer** → **Application Load Balancer**.
   - Name: `Secure-App-ALB`. Scheme: `Internet-facing`. 
   - Network mapping: Select **both Public Subnets** (10.0.1.0/24 and 10.0.2.0/24).
   - Security Groups: Attach `ALB-SG`.
   - Listener: HTTP, Port 80. Default action: Forward to `App-TG`.
   - Create.

3. Wait for the ALB state to become `Active`. Copy the **ALB DNS name** (e.g., `Secure-App-ALB-1234567890.elb.amazonaws.com`). Open a browser and hit this DNS. You should see `"Nginx Frontend Alive"`. This confirms the ALB → EC2 forwarding path is functional.

---

## Phase 6: L3/L4 Lockdown (ALB SG → CloudFront Prefix List)

**Objective**: Eliminate direct internet exposure of the ALB. Allow only SYN packets sourced from CloudFront's global egress IPs to reach the ALB ENI.

**Console Steps**:

1. Navigate to **VPC** → **Managed prefix lists**.
2. Find the prefix list named **`com.amazonaws.global.cloudfront.origin-facing`**. Copy its ID (e.g., `pl-12345678`). This list is maintained by AWS and contains all current IPv4 CIDRs used by CloudFront edge locations to connect to origins.
3. Navigate to **EC2** → **Security Groups** → Select `ALB-SG` → **Edit inbound rules**.
4. **Remove** the existing `HTTP 0.0.0.0/0` rule.
5. **Add new rule**: Type `HTTP` (80), Source: **Prefix list ID** (paste `pl-12345678`).
6. Save rules.

**Verification**: Open an incognito browser and hit your ALB DNS directly. The connection will **time out** because your home IP is not in the CloudFront prefix list. Only requests routed through CloudFront's global network will be allowed at the L3 level.

---

## Phase 7: L7 Lockdown (CloudFront Custom Header + ALB Listener Rule)

**Objective**: Add application-layer defense. CloudFront injects a static shared-secret header into the HTTP request. The ALB validates this header and rejects requests without it, even if they somehow bypass the L3 prefix list (e.g., via DNS rebinding or compromised AWS internal network paths).

**Console Steps**:

**Step 7.1: Create CloudFront Distribution**

1. Navigate to **CloudFront** → **Distributions** → **Create distribution**.
2. **Origin**:
   - Origin domain: Paste your **ALB DNS name**.
   - Protocol: `HTTP Only`.
   - **Add custom header**:
     - Header name: `X-Origin-Secret`
     - Value: `MySecureToken123`
3. **Default cache behavior**:
   - Viewer protocol policy: `HTTP and HTTPS` (or redirect).
   - Cache policy: `CachingDisabled` (for testing; enable later for production).
4. **Settings**: Leave defaults. Click **Create distribution**. Wait ~10 minutes for deployment.

**Step 7.2: Configure ALB Listener to Validate the Header**

1. Navigate to **EC2** → **Load Balancers** → Select your ALB → **Listeners** tab.
2. Click on the HTTP:80 listener → **View/edit rules**.
3. Click the **+** (insert rule) *above* the default rule:
   - **IF** (Add condition) → **Header**:
     - Header name: `X-Origin-Secret`
     - Value: `MySecureToken123`
   - **THEN** (Add action) → **Forward to** `App-TG`.
   - Click **Save**.
4. Click on the **Default rule** at the bottom. Edit its action:
   - Change action to **Return fixed response**.
   - Response code: `403`.
   - Response body: `Direct ALB access is forbidden.`
   - Click **Save**.

---

## Final Verification (End-to-End)

1. **CloudFront Test**: Copy your CloudFront distribution domain name (e.g., `dxxxxx.cloudfront.net`). Open a browser and navigate to `http://dxxxxx.cloudfront.net`. 
   - You should see `"Nginx Frontend Alive"`.
   - Navigate to `/api/`. You should see `"Backend: ip-10-0-11-xxx"`.

2. **Direct ALB Test**: Open a browser and navigate directly to your ALB DNS (`http://Secure-App-ALB-xxx.elb.amazonaws.com`).
   - You will receive either a **connection timeout** (due to the L3 Prefix List rule) OR a **403 Forbidden** (if the L3 rule accidentally had a hole, the L7 listener rule catches it). The strictest combination ensures complete invisibility.

---

## Summary of the Defense-in-Depth Layers

| Layer | Location | Mechanism | Protects Against |
| :--- | :--- | :--- | :--- |
| **L3/L4 FW** | VPC Hypervisor (ALB SG) | Prefix List matching against CloudFront egress IPs | Direct IP spoofing, volumetric DDoS bypassing CloudFront |
| **L7 Header** | ALB Listener Rule | Shared-secret HTTP header injection + validation | DNS rebinding attacks, compromised internal traffic |
| **Stateful SNAT** | NAT Gateway | Private subnets lack public IPs; outbound only | Prevents external initiation of connections to EC2s |
| **SG Reference** | App Server SG | Ingress allowed only from `ALB-SG` ID | Prevents lateral movement from compromised EC2s in other subnets |