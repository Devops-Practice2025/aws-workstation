Understood. Let's drop RDS, focus purely on **Nginx + Backend**, and step through **Phases 3 to 7 via the AWS Console** so you can visually connect every component.

Before we click, here is the **precise technical relationship** between Security Groups, ALB, and CloudFront.

---

## The Technical Relationship (No Analogies)

**1. Security Groups are L3/L4 Stateful Firewalls attached to ENIs.**

- **ALB Security Group**: Filters packets *before* they reach the ALB's Elastic Network Interface (ENI). 
- **App Server Security Group**: Filters packets *before* they reach the EC2 instance's ENI.

**2. The ALB acts as a L7 Reverse Proxy.**

- It terminates the client TCP connection (from CloudFront) and establishes a *new* TCP connection to the EC2 instance. 
- This means the EC2 instance **never sees the original client IP**. It only sees the ALB's private IP as the source.

**3. CloudFront integrates via Origin Domain Name.**

- CloudFront establishes TCP connections from its edge locations to your ALB's DNS name. The source IP of these packets are CloudFront's egress IPs.

**4. The Lockdown Mechanism:**

- **L3/L4 Lockdown (SG)**: We restrict the ALB SG inbound rule to **CloudFront's managed prefix list** (`com.amazonaws.global.cloudfront.origin-facing`). This is a dynamic list of CIDR blocks representing all CloudFront edge egress IPs. Only packets sourced from these IPs reach the ALB.
- **L7 Lockdown (ALB Listener Rule)**: CloudFront injects a static custom HTTP header (e.g., `X-Origin-Verify: MySecret`). We configure the ALB listener to **evaluate this header**. If missing or incorrect, the ALB returns `HTTP 403` *without* forwarding to the target group. This defends against DNS rebinding and IP spoofing attacks.

---

## Step-by-Step Console Guide (Phases 3 to 7, No RDS)

### Prerequisites
- Your VPC, 2 Public Subnets, 2 Private Subnets, IGW, NAT Gateways, and Route Tables from Phases 1 & 2 are **already created**.
- You know the **Subnet IDs** for Public-A, Public-B, Private-A, Private-B.

---

### Phase 3: Create Security Groups

**Step 3.1: Create the ALB Security Group**

1. Go to **VPC** → **Security Groups** → **Create security group**.
2. **Name**: `ALB-SG`
3. **VPC**: Select your `SecureVPC` (10.0.0.0/16).
4. **Inbound rules** (Add these):
   - **Type**: HTTPS (443) | **Source**: `0.0.0.0/0` *(We will change this to the CloudFront Prefix List in Phase 6, but leave it open for now so we can test)*.
5. **Outbound rules**: Leave default (Allow all).
6. Click **Create**.

---

**Step 3.2: Create the App Server Security Group**

1. Click **Create security group** again.
2. **Name**: `App-SG`
3. **VPC**: Select your `SecureVPC`.
4. **Inbound rules**:
   - **Type**: HTTP (80) | **Source**: **Select "Custom" and paste the ALB-SG ID** (e.g., `sg-0a1b2c3d4e5f67890`). 
     - *Why?* This is a **Security Group Reference**. The hypervisor resolves this to the private IPs of the ALB's ENIs. Only the ALB can talk to your EC2s.
   - **Type**: SSH (22) | **Source**: Your IP `x.x.x.x/32` (for debugging).
5. **Outbound rules**: Leave default (Allow all) so instances can reach the internet via NAT Gateway.
6. Click **Create**.

---

### Phase 4: Launch EC2 Instances (Nginx + Backend) in Private Subnets

**Step 4.1: Write the User Data Script**

Copy this script into a text file. This installs Nginx (frontend) and a Python Flask backend.

```bash
#!/bin/bash
dnf update -y
dnf install -y nginx python3 python3-pip
systemctl enable nginx

# Write the backend application
cat << 'EOT' > /home/ec2-user/app.py
from flask import Flask, jsonify
import socket
app = Flask(__name__)

@app.route('/')
def hello():
    return f"Hello from Backend: {socket.gethostname()}"

@app.route('/health')
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOT

pip3 install flask
nohup python3 /home/ec2-user/app.py > /var/log/backend.log 2>&1 &

# Write Nginx reverse proxy configuration
cat << 'EOT' > /etc/nginx/conf.d/app.conf
server {
    listen 80;
    location /api/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host $host;
    }
    location / {
        return 200 'Nginx Frontend is Alive!\n';
        add_header Content-Type text/plain;
    }
    location /health {
        return 200 'healthy\n';
        add_header Content-Type text/plain;
    }
}
EOT

systemctl restart nginx
```

---

**Step 4.2: Launch the EC2 Instances**

1. Go to **EC2** → **Instances** → **Launch instance**.
2. **Name**: `App-Server-A`
3. **AMI**: Search for your `devops-practice` AMI.
4. **Instance type**: `t3.micro` or `t2.micro`.
5. **Key pair**: Select an existing one or create a new one (you'll need this for SSH).
6. **Network settings**:
   - VPC: Your `SecureVPC`.
   - Subnet: Select **Private Subnet A** (`10.0.11.0/24`).
   - Auto-assign public IP: **Disable** (critical).
   - Firewall (SG): Select **App-SG**.
7. **Advanced details**:
   - Scroll to **User data**.
   - Paste the entire bash script from Step 4.1.
8. Click **Launch instance**.
9. **Repeat the exact same steps** for a second instance, but this time select **Private Subnet B** (`10.0.12.0/24`). Name it `App-Server-B`.

---

### Phase 5: Create Target Group and ALB

**Step 5.1: Create Target Group**

1. Go to **EC2** → **Target Groups** → **Create target group**.
2. **Target type**: `Instances`.
3. **Name**: `App-TG`.
4. **Protocol**: HTTP | **Port**: 80.
5. **VPC**: Your `SecureVPC`.
6. **Health checks**:
   - Protocol: HTTP | Path: `/health`.
   - Advanced settings: Healthy threshold = 2, Interval = 30 seconds.
7. Click **Next**.
8. On the **Register targets** page, select **App-Server-A** and **App-Server-B**. Click **Include as pending below**. Click **Create target group**.

---

**Step 5.2: Create the ALB**

1. Go to **EC2** → **Load Balancers** → **Create load balancer** → **Application Load Balancer**.
2. **Name**: `Secure-App-ALB`.
3. **Scheme**: **Internet-facing** (We will lock it down via SG later).
4. **Network mapping**:
   - VPC: Your `SecureVPC`.
   - Mappings: Select **both Public Subnets** (`10.0.1.0/24` and `10.0.2.0/24`). *Why Public?* The ALB must be reachable by CloudFront, but we will block all non-CloudFront IPs via the SG.
5. **Security groups**: Select the `ALB-SG` you created.
6. **Listeners and routing**:
   - Protocol: **HTTP** | Port: **80**.
   - Default action: Forward to `App-TG`.
7. Click **Create load balancer**.
8. **Wait 2 minutes** for the ALB to become `Active`.
9. Go to the ALB details and copy its **DNS name** (e.g., `Secure-App-ALB-1234567890.elb.amazonaws.com`). 
10. Open a browser and hit `http://<ALB-DNS>`. You should see `"Nginx Frontend is Alive!"`. Hit `/health` to see `healthy`. This proves your ALB → EC2 chain works.

---

### Phase 6: Lock Down the ALB to ONLY CloudFront (L3/L4)

**Step 6.1: Get the CloudFront Prefix List ID**

1. Go to **VPC** → **Managed prefix lists** (left menu).
2. Search for `com.amazonaws.global.cloudfront.origin-facing`.
3. Copy its **Prefix list ID** (e.g., `pl-12345678`). This list contains all current CloudFront egress IPv4 CIDRs.

---

**Step 6.2: Update the ALB Security Group**

1. Go back to **EC2** → **Security Groups** → Select `ALB-SG`.
2. Click **Edit inbound rules**.
3. **Remove** the existing HTTPS rule for `0.0.0.0/0`.
4. Click **Add rule**:
   - Type: **HTTP** (80) | Source: **Prefix list ID** (paste `pl-xxxxxxxx`).
   - (Optional) Add **HTTPS** (443) as well if you want SSL later.
5. Click **Save rules**.

**Now test**: Open an **incognito window** and try to hit `http://<ALB-DNS>` directly. The connection will **time out or hang**. Your ALB is now invisible to the public internet. *Only CloudFront can reach it.*

---

### Phase 7: Create CloudFront Distribution (The Edge Proxy)

**Step 7.1: Add a Custom Header (L7 Shared Secret)**

CloudFront can inject a header into every request sent to the ALB.

1. Go to **CloudFront** → **Distributions** → **Create distribution**.
2. **Origin**:
   - Origin domain: Paste your `ALB-DNS`.
   - Protocol: **HTTP Only** (for now; you can add SSL later).
   - **Add custom header**:
     - Header name: `X-Origin-Secret`
     - Value: `MySuperSecret123` (remember this).
3. **Default cache behavior**:
   - Viewer protocol policy: **Redirect HTTP to HTTPS** (or HTTP if testing).
   - Allowed methods: GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE.
   - Cache policy: **CachingDisabled** (so we see live backend responses).
4. **Settings**:
   - Price class: Use all edge locations (or choose cheaper).
   - Alternate domain names (CNAMEs): Leave blank or add your custom domain.
   - SSL Certificate: **Default CloudFront certificate** (or ACM if using custom domain).
   - Default root object: Leave blank (or `/`).
5. Click **Create distribution**. Wait ~10-15 minutes for deployment. (You can proceed while waiting).

---

**Step 7.2: Validate the Custom Header on the ALB (L7 Defense)**

While CloudFront deploys, set up the ALB to reject requests without the header. This is defense-in-depth.

1. Go to **EC2** → **Load Balancers** → Select your ALB → **Listeners** tab.
2. Click on the HTTP:80 listener → **View/edit rules**.
3. Click the **+** (insert rule) above the default rule.
4. **IF** (Add condition) → **Header**:
   - Header name: `X-Origin-Secret`
   - Value: `MySuperSecret123`
5. **THEN** (Add action) → **Forward to** `App-TG`.
6. Click **Save**.
7. Now, edit the **Default rule** (the bottom one). Change its action to **Return fixed response**:
   - Response code: `403`
   - Response body: `Access Denied - Direct ALB Access Blocked`.
8. Click **Save**.

**What happened?** If a request hits the ALB without the exact secret header (e.g., someone directly hits the ALB DNS), it hits the default rule and gets a 403. Only CloudFront (which injects the header) forwards to your EC2s.

---

### Final Verification

Once your CloudFront distribution is **Deployed** (status turns green):

1. Copy the CloudFront **Distribution domain name** (e.g., `d1234.cloudfront.net`).
2. Open a browser and go to `http://d1234.cloudfront.net`.
3. You should see `"Nginx Frontend is Alive!"`.
4. Go to `http://d1234.cloudfront.net/api/`.
5. You should see `"Hello from Backend: ip-10-0-11-xxx"`.

**Try bypassing**: Open a new tab and hit your **ALB DNS directly**. You should get a **403 Forbidden** or a timeout (depending on the SG + Listener rules). 

---

## Summary of What You Just Built

| Component | What it does | Where you placed it |
| :--- | :--- | :--- |
| **ALB SG** | L3/L4 Firewall. Allows only CloudFront IPs (Prefix List) via HTTP/HTTPS. | Attached to ALB. |
| **App SG** | L3/L4 Firewall. Allows only the ALB's ENI IPs (SG Reference) on port 80. | Attached to EC2s. |
| **ALB Listener Rule** | L7 Application gateway. Rejects requests missing the `X-Origin-Secret` header. | Listener on ALB. |
| **EC2 User Data** | Bootstraps Nginx (frontend) + Flask (backend) on launch. | Applied at instance creation. |
| **CloudFront** | Global reverse proxy. Caches content and injects the secret header. | Edge network. |