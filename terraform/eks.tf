module "eks" {
    source = "terraform-aws-modules/eks/aws"
    version = "~> 20.0"
    cluster_name = var.cluster_name
    
    vpc_id = module.vpc.vpc_id
    subnet_ids = module.vpc.private_subnets
    enable_irsa = true
    cluster_endpoint_public_access = true
    cluster_endpoint_private_access = false
    eks_managed_node_groups = {
        default = {
            min_size = 1
            max_size = 3
            desired_size = 2
            instance_types = ["t3.medium"]
        }
    }
}