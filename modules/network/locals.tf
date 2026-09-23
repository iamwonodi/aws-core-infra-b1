locals {
  all_network = "0.0.0.0/0"

  public_sg_name        = "public-tier"
  public_sg_description = "Security group for public-tier infrastructure such as application load balancers and public gateway resources."

  private_sg_name        = "private-tier"
  private_sg_description = "Security group for frontend applications, publicly accessible APIs, and database GUI workloads in private subnets."

  internal_sg_name        = "internal-tier"
  internal_sg_description = "Security group for backend application services and internal workloads in internal subnets."

  isolated_sg_name        = "isolated-tier"
  isolated_sg_description = "Security group for isolated database workloads with no default internet access."

  endpoint_sg_name        = "vpc-endpoint"
  endpoint_sg_description = "Security group for VPC endpoints which provides private connectivity to the AWS service."

  # The required public entry points for the load balancer.
  endpoint_ingress_ports = [443]

  # Every tier whose hosts call AWS services. The public tier runs none.
  endpoint_client_security_groups = {
    private  = module.private_sg.security_group_id
    internal = module.internal_sg.security_group_id
    isolated = module.isolated_sg.security_group_id
  }
}
