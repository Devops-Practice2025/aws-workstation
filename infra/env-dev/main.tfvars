env           = "dev"
project_name  = "test-app"
vpc = {
  cidr               = "10.0.0.0/16"
  public_subnets     = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnets        = ["10.10.2.0/24", "10.10.3.0/24"]
  availability_zones = ["us-east-1a", "us-east-1b"]
}
policy_name = "Administrator Access"
