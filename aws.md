Absolutely. Here is a **complete, English-only, concept-driven AWS CLI guide** to build your **Nginx Frontend + Backend** application on the secure 2-tier architecture we designed. 

Instead of just dumping commands, I will explain **"The Concept"** before every major CLI block—so you understand *why* AWS designed these components this way. This is exactly what interviewers want to hear.

---

## Architecture Recap (The "Why")
- **Edge (CloudFront)**: Global caching + DDoS shield.
- **Public Tier (ALB + NAT)**: Receives traffic; allows *outbound-only* internet for private servers.
- **Private Tier (App/Nginx)**: Runs business logic, cannot be reached from the internet.
- **Data Tier (RDS)**: Isolated database with zero internet access.

---

## Prerequisites & Variables
Set these environment variables. They make the script dynamic and save you from typing IDs repeatedly.

```bash
export AWS_REGION="us-east-1"
export VPC_CIDR="10.0.0.0/16"
export PUB_A_CIDR="10.0.1.0/24"
export PUB_B_CIDR="10.0.2.0/24"
export PRIV_A_CIDR="10.0.11.0/24"
export PRIV_B_CIDR="10.0.12.0/24"
export DB_A_CIDR="10.0.21.0/24"
export DB_B_CIDR="10.0.22.0/24"
export AZ_A=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[0].ZoneName' --output text)
export AZ_B=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[1].ZoneName' --output text)
export AMI_ID=$(aws ec2 describe-images --filters "Name=name,Values=devops-practice" --query 'Images[0].ImageId' --output text)
export MY_IP=$(curl -s https://checkip.amazonaws.com)/32
```

---

## Phase 1: VPC & Subnets (The Network Foundation)
**The Concept**: A VPC is your private data center in the cloud. We divide it into **Public** (has internet access via IGW) and **Private** (no direct internet). We stretch this across **2 Availability Zones (AZs)** to ensure if one AWS data center burns down, your app stays live.

```bash
# 1.1 Create VPC
export VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=SecureVPC

# 1.2 Create Internet Gateway (IGW) - The "front door" to the internet
export IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# 1.3 Create Subnets (6 subnets total)
# Public Subnets (For ALB & NAT)
export PUB_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUB_A_CIDR --availability-zone $AZ_A --query 'Subnet.SubnetId' --output text)
export PUB_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUB_B_CIDR --availability-zone $AZ_B --query 'Subnet.SubnetId' --output text)
# Private App Subnets (For Nginx + Backend)
export PRIV_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIV_A_CIDR --availability-zone $AZ_A --query 'Subnet.SubnetId' --output text)
export PRIV_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PRIV_B_CIDR --availability-zone $AZ_B --query 'Subnet.SubnetId' --output text)
# Private DB Subnets (For RDS)
export DB_SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $DB_A_CIDR --availability-zone $AZ_A --query 'Subnet.SubnetId' --output text)
export DB_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $DB_B_CIDR --availability-zone $AZ_B --query 'Subnet.SubnetId' --output text)

# Enable "Auto-assign public IP" for Public subnets (so ALB can talk to IGW)
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_A --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_B --map-public-ip-on-launch
```

---

## Phase 2: Route Tables + NAT Gateway (The Traffic Controllers)
**The Concept**: 
- **Public Route Table**: Routes `0.0.0.0/0` (all internet traffic) to the IGW. 
- **Private Route Table**: Routes `0.0.0.0/0` to the **NAT Gateway**. 
- **NAT Gateway Concept**: It sits in the public subnet and acts as a proxy. It gives your private servers a public IP *to talk out* (e.g., download updates) but blocks *incoming* internet attacks. **Critical**: We deploy one NAT per AZ to prevent cross-AZ data transfer costs and ensure high availability.

```bash
# 2.1 Create Route Tables
export PUBLIC_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
export PRIVATE_RT_A=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
export PRIVATE_RT_B=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)

# 2.2 Add default routes
# Public -> IGW
aws ec2 create-route --route-table-id $PUBLIC_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
# Private -> NAT (will be added after NAT creation)

# 2.3 Associate Subnets to Route Tables
aws ec2 associate-route-table --subnet-id $PUB_SUBNET_A --route-table-id $PUBLIC_RT
aws ec2 associate-route-table --subnet-id $PUB_SUBNET_B --route-table-id $PUBLIC_RT
aws ec2 associate-route-table --subnet-id $PRIV_SUBNET_A --route-table-id $PRIVATE_RT_A
aws ec2 associate-route-table --subnet-id $PRIV_SUBNET_B --route-table-id $PRIVATE_RT_B

# 2.4 Create NAT Gateways (One per AZ)
# Allocate Elastic IPs (NAT needs a static public IP)
export EIP_NAT_A=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
export EIP_NAT_B=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)

# Create NAT GW in PUBLIC subnets
export NAT_A=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_A --allocation-id $EIP_NAT_A --query 'NatGateway.NatGatewayId' --output text)
export NAT_B=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_B --allocation-id $EIP_NAT_B --query 'NatGateway.NatGatewayId' --output text)

# Wait for NAT to be available (takes ~1-2 mins)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_A $NAT_B

# 2.5 Add routes to Private Route Tables pointing to the NATs
aws ec2 create-route --route-table-id $PRIVATE_RT_A --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_A
aws ec2 create-route --route-table-id $PRIVATE_RT_B --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_B
```

---

## Phase 3: Security Groups (The Virtual Firewalls)
**The Concept**: Security Groups (SGs) are stateful firewalls attached to your resources. Instead of using IPs, we reference **other Security Group IDs**. This is a native AWS superpower—even if the IP of your app server changes (auto-scaling), the database SG automatically allows the new instance because it looks at the *SG ID*, not the IP.

```bash
# 3.1 ALB SG (Allows internet traffic from CloudFront only)
export SG_ALB=$(aws ec2 create-security-group --group-name ALB-SG --description "ALB Security Group" --vpc-id $VPC_ID --query 'GroupId' --output text)
# NOTE: We will restrict to CloudFront IPs later. For now, open HTTPS.
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 443 --cidr 0.0.0.0/0

# 3.2 App Server SG (Allows traffic ONLY from the ALB SG)
export SG_APP=$(aws ec2 create-security-group --group-name App-SG --description "App Server SG" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 80 --source-group $SG_ALB
aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 443 --source-group $SG_ALB
# Allow SSH from your IP only (for debugging)
aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 22 --cidr $MY_IP

# 3.3 Database SG (Allows traffic ONLY from the App Server SG)
export SG_DB=$(aws ec2 create-security-group --group-name DB-SG --description "Database SG" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_DB --protocol tcp --port 3306 --source-group $SG_APP
# Note: No internet access whatsoever for this SG.
```

---

## Phase 4: Application Load Balancer (ALB)
**The Concept**: ALB works at Layer 7 (HTTP/HTTPS). It distributes traffic, terminates SSL, and performs health checks. We deploy it as "internet-facing" but we will later lock it down to CloudFront.

```bash
# 4.1 Create Target Group (where the ALB sends traffic)
export TG_APP=$(aws elbv2 create-target-group --name app-targets --protocol HTTP --port 80 --vpc-id $VPC_ID --health-check-path /health --health-check-interval-seconds 30 --query 'TargetGroups[0].TargetGroupArn' --output text)

# 4.2 Create ALB (Internet-facing, cross-zone enabled)
export ALB_ARN=$(aws elbv2 create-load-balancer --name secure-app-alb --subnets $PUB_SUBNET_A $PUB_SUBNET_B --security-groups $SG_ALB --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# 4.3 Create Listener (HTTPS) - For now, use HTTP for testing; add ACM cert later.
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_APP

# Get ALB DNS name (you'll use this for CloudFront)
export ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
echo "ALB DNS: $ALB_DNS"
```

---

## Phase 5: Compute - Nginx Frontend + Backend (User Data)
**The Concept**: We launch EC2 instances in the **Private Subnets**. They have **no public IP**. They use the NAT Gateway to install dependencies (Nginx, Node.js/Python). 
The **User Data script** is the "golden image" configurator—it installs Nginx as a reverse proxy for the frontend, and a simple backend API (e.g., Python Flask or Node.js) that reads the Database hostname from AWS metadata.

```bash
# 5.1 Create an IAM Role for EC2 to fetch RDS hostname securely (Optional but recommended)
# (Skipping full IAM creation for brevity, but in prod, attach AmazonSSMManagedInstanceCore + RDS access)

# 5.2 User Data Script (Installs Nginx + Python Backend)
cat << 'EOF' > user-data.sh
#!/bin/bash
# Update system
dnf update -y  # Amazon Linux 2023 uses dnf
# Install Nginx & Node.js/Python
dnf install -y nginx python3 python3-pip
systemctl enable nginx

# --- BACKEND (Python Flask) ---
cat << 'EOT' > /home/ec2-user/app.py
from flask import Flask, jsonify
import os
import socket
app = Flask(__name__)

@app.route('/')
def hello():
    return "Hello from Backend Server: " + socket.gethostname()

@app.route('/health')
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOT
pip3 install flask

# Run backend in background
nohup python3 /home/ec2-user/app.py > /var/log/backend.log 2>&1 &

# --- NGINX FRONTEND (Reverse Proxy to Backend) ---
cat << 'EOT' > /etc/nginx/conf.d/app.conf
server {
    listen 80;
    location /api/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host $host;
    }
    location / {
        return 200 'Nginx Frontend is Alive!';
        add_header Content-Type text/plain;
    }
    location /health {
        return 200 'healthy';
        add_header Content-Type text/plain;
    }
}
EOT
systemctl restart nginx
EOF

# 5.3 Launch Instances in PRIVATE subnets (NO public IP)
export INSTANCE_A=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --subnet-id $PRIV_SUBNET_A \
    --security-group-ids $SG_APP \
    --user-data file://user-data.sh \
    --associate-public-ip-address false \
    --query 'Instances[0].InstanceId' --output text)

export INSTANCE_B=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type t3.micro \
    --subnet-id $PRIV_SUBNET_B \
    --security-group-ids $SG_APP \
    --user-data file://user-data.sh \
    --associate-public-ip-address false \
    --query 'Instances[0].InstanceId' --output text)

# 5.4 Register instances to the Target Group
aws elbv2 register-targets --target-group-arn $TG_APP --targets Id=$INSTANCE_A Id=$INSTANCE_B
```

---

## Phase 6: RDS Database (The Data Tier)
**The Concept**: RDS runs in the **DB Subnets** (which also have no internet route). We enable **Multi-AZ** so AWS automatically replicates data to a standby instance in a different AZ. The App Servers connect to the **RDS Endpoint** (DNS name), which always points to the primary.

```bash
# 6.1 Create DB Subnet Group (Tells RDS which subnets to use)
aws rds create-db-subnet-group --db-subnet-group-name secure-db-subnet-group --db-subnet-group-description "Subnets for RDS" --subnet-ids $DB_SUBNET_A $DB_SUBNET_B

# 6.2 Create RDS (MySQL, Multi-AZ)
export RDS_PASSWORD="YourSecurePassword123!" # CHANGE THIS!

aws rds create-db-instance \
    --db-instance-identifier secure-app-db \
    --db-instance-class db.t3.micro \
    --engine mysql \
    --master-username admin_user \
    --master-user-password $RDS_PASSWORD \
    --allocated-storage 20 \
    --vpc-security-group-ids $SG_DB \
    --db-subnet-group-name secure-db-subnet-group \
    --multi-az true \
    --backup-retention-period 7 \
    --publicly-accessible false

# Wait for RDS to be available (takes ~5 mins)
aws rds wait db-instance-available --db-instance-identifier secure-app-db

# Get the RDS Endpoint (Give this to your developers)
export RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier secure-app-db --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"
```

---

## Phase 7: CloudFront + WAF (The Edge Layer)
**The Concept**: CloudFront caches your content globally. We connect it to our ALB using the **"Origin Domain Name"**. Crucially, we configure a **Custom Header** (e.g., `X-Auth-Token: Secret`) on CloudFront and validate that header on the ALB to ensure only CloudFront can talk to your ALB—blocking direct internet attacks on your ALB.

```bash
# 7.1 Create a WAF Web ACL (Basic DDoS + SQL Injection protection)
export WAF_ARN=$(aws wafv2 create-web-acl \
    --name secure-app-waf \
    --scope CLOUDFRONT \
    --default-action Allow={} \
    --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=secureWaf \
    --query 'Summary.ARN' --output text)

# 7.2 Create CloudFront Distribution
# We use the ALB DNS as the Origin. 
# We add a custom header "X-Origin-Verify: MySecret123".
export CF_DISTRO=$(aws cloudfront create-distribution \
    --origin-domain-name $ALB_DNS \
    --default-root-object index.html \
    --origin-id "ALB-Origin" \
    --origin-custom-header "X-Origin-Verify:MySecret123" \
    --viewer-protocol-policy redirect-to-https \
    --query 'Distribution.Id' --output text)

echo "CloudFront Distribution ID: $CF_DISTRO"
echo "CloudFront Domain: $(aws cloudfront list-distributions --query 'DistributionList.Items[?Id==`'$CF_DISTRO'`].DomainName' --output text)"
```

---

## Phase 8: The FINAL Lockdown (Security Group Update)
**The Concept**: Now that CloudFront is live, we update the ALB Security Group to **ONLY** accept traffic from CloudFront's IP ranges. AWS publishes a managed prefix list called `com.amazonaws.global.cloudfront.origin-facing` for this exact purpose.

```bash
# 8.1 Get CloudFront Prefix List ID
export CF_PREFIX_LIST=$(aws ec2 describe-managed-prefix-lists --query "PrefixLists[?PrefixListName=='com.amazonaws.global.cloudfront.origin-facing'].PrefixListId" --output text)

# 8.2 Revoke the old 0.0.0.0/0 rule and add the Prefix List rule
aws ec2 revoke-security-group-ingress --group-id $SG_ALB --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 443 --prefix-list-ids $CF_PREFIX_LIST

# Now your ALB is completely invisible to the raw internet. Only CloudFront edge locations can hit it.
```

---

## How to Test Your Architecture
1. **Get your CloudFront URL**: `https://<your-cloudfront-id>.cloudfront.net`
2. Hit `/` → You should see `"Nginx Frontend is Alive!"` (served from the edge or private EC2).
3. Hit `/api/` → You should see the backend hostname (proving the proxy chain works).
4. Try hitting your **ALB DNS** directly in a browser. It will timeout/refuse connection because your ALB SG now only allows CloudFront IPs. **This proves your security layer is working perfectly.**

---

## Summary of Concepts for your Interview
| Component | The 10-Second Interview Pitch |
| :--- | :--- |
| **NAT Gateway** | "Enables outbound internet for private instances without exposing them to inbound threats. One per AZ avoids data transfer taxes." |
| **Security Group Referencing** | "Instead of hardcoding IPs, I reference SG IDs. This allows dynamic scaling—new instances are automatically whitelisted by the DB." |
| **CloudFront Origin Header** | "I add a custom header at the edge and validate it on the ALB. This guarantees that all ALB traffic originated from CloudFront, preventing DDoS bypass." |
| **Multi-AZ RDS** | "Automatic synchronous replication to a standby AZ. In a failover, AWS updates the DNS endpoint automatically—zero code changes required." |
| **Private Subnets** | "Compute and data are completely isolated from the internet. The only exit path is the controlled NAT Gateway for necessary updates." |