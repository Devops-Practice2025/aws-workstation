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