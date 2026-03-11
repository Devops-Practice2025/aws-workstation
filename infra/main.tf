module "vpc" {
    source = "./modules/vpc"
    cidr = var.vpc["cidr"]
    public_subnets = var.vpc["public_subnets"]
    private_subnets = var.vpc["private_subnets"]
    availability_zones = var.vpc["availability_zones"]
    env = var.env
    project_name = var.project_name
}