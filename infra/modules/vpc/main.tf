resource "aws_vpc" "main" {
  cidr_block           = var.vpc.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-${var.env}-vpc"
  }
}



# Public Subnets (for Jump Server and NAT Gateway)
resource "aws_subnet" "public" {
  count = length(var.public_subnets)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.env}-public-subnet-${count.index + 1}"
    Type = "Public"
  }
}

# Private Subnets (for App Server)
resource "aws_subnet" "private" {
    count = length(var.private_subnets)

    vpc_id                  = aws_vpc.main.id
    cidr_block              = var.private_subnets[count.index]
    availability_zone       = var.availability_zones[count.index]

    tags = {
    Name = "${var.project_name}-${var.env}-private-subnet-${count.index + 1}"
    Type = "Private"
  }

  
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.env}-igw"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat-ip" {
  count = length(var.availability_zones)

  domain = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-${var.env}-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "nat-gw" {

  count = length(var.availability_zones)

  allocation_id = aws_eip.nat-ip[count.index].id
  subnet_id = aws_subnet.public[count.index].id
  depends_on = [ aws_internet_gateway.main ]
  tags = {
    name = "${var.project_name}-${var.env}-nat-gw-${count.index + 1}" 
  }}

}
