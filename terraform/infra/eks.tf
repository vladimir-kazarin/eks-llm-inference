module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.allowed_cidrs
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
  }

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2
      labels         = { workload = "system" }
      # The production-stack router image bundles torch CUDA libs (several GB);
      # the AMI's default 20 GiB root fills up and the node goes DiskPressure.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 60
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    gpu = {
      ami_type       = "AL2023_x86_64_NVIDIA"
      instance_types = [var.gpu_instance_type]
      # Quota: 8 G-family vCPUs = exactly 2x g5.xlarge. Do not raise.
      min_size     = 2
      max_size     = 2
      desired_size = 2
      labels = {
        workload = "llm"
        # nvidia-device-plugin's default node affinity requires this label (no NFD installed).
        "nvidia.com/gpu.present" = "true"
      }
      taints = {
        gpu = { key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" }
      }
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
}
