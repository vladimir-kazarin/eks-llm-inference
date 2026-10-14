# Only AZs that actually offer the GPU instance type.
data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.gpu_instance_type]
  }
}

locals {
  azs = slice(sort(data.aws_ec2_instance_type_offerings.gpu.locations), 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.cluster_name
  cidr = "10.0.0.0/16"
  azs  = local.azs

  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.64.0/24", "10.0.65.0/24"]

  enable_nat_gateway = true
  # Cost trade-off: one NAT for both AZs. Production multi-AZ would use one per AZ.
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
