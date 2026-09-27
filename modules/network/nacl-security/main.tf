module "nacl_security" {
  source = "git::https://github.com/iamwonodi/terraform-aws-nacl-security.git?ref=v1.0.2"

  vpc_id       = var.vpc_id
  project_name = var.project_name
  environment  = var.environment

  public_subnet_ids   = var.public_subnet_ids
  private_subnet_ids  = var.private_subnet_ids
  internal_subnet_ids = var.internal_subnet_ids
  isolated_subnet_ids = var.isolated_subnet_ids

  # ============================================================================
  # PUBLIC SUBNET
  #
  # Contains the Internet Gateway-facing/NAT Gateway resources.
  #
  # Private and Internal subnets use the NAT Gateway for outbound Internet
  # access. Therefore:
  #
  #   Private/Internal -> NAT      : destination 80/443
  #   Internet -> NAT return       : destination ephemeral
  #   NAT -> Internet              : destination 80/443
  #   NAT -> Private/Internal      : destination ephemeral
  #
  # No unsolicited Internet -> Public HTTP/HTTPS is required by the current
  # architecture.
  # ============================================================================

  public_ingress_rules = local.rules.public_ingress

  public_egress_rules = local.rules.public_egress

  # ============================================================================
  # PRIVATE SUBNET
  #
  # Contains the CloudFront VPC Origin ALB and private workloads.
  #
  # CloudFront -> Private ALB:
  #   AWS does NOT evaluate inbound NACL rules for CloudFront VPC Origin
  #   traffic.
  #
  # Return traffic:
  #   Private -> CloudFront uses ephemeral destination ports.
  #
  # Private -> Internal/Isolated:
  #   NACL permits the tier-to-tier TCP path.
  #   Security groups enforce the actual application/listener ports.
  #
  # Public -> Private:
  #   Only NAT return traffic is permitted.
  # ============================================================================

  private_ingress_rules = local.rules.private_ingress

  private_egress_rules = local.rules.private_egress

  # ============================================================================
  # INTERNAL SUBNET
  #
  # Contains the internal ALB and backend/internal workloads.
  #
  # Private -> Internal:
  #   New connections are allowed at the subnet boundary.
  #   SGs determine the actual service port.
  #
  # Internal -> Isolated:
  #   Backend services may initiate connections to databases/restricted
  #   workloads.
  #
  # Internal -> Internet:
  #   Uses the NAT Gateway in Public.
  # ============================================================================

  internal_ingress_rules = local.rules.internal_ingress

  internal_egress_rules = local.rules.internal_egress

  # ============================================================================
  # ISOLATED SUBNET
  #
  # No Internet/NAT path.
  #
  # Private and Internal are allowed to initiate TCP connections toward
  # isolated workloads. The actual database/application ports remain controlled
  # by security groups.
  #
  # Isolated only returns traffic; it does not initiate connections back to
  # Private/Internal under this subnet-boundary policy.
  #
  # The one way out: HTTPS to S3 through the gateway endpoint (scripts, and the
  # layers of every ECR image), which is reached at S3's own addresses. A network
  # ACL cannot name a prefix list, so the rule says 0.0.0.0/0; the isolated route
  # table has no internet or NAT route, so S3 is all it can reach. Its security
  # group narrows it to S3's prefix list.
  # ============================================================================

  isolated_ingress_rules = local.rules.isolated_ingress

  isolated_egress_rules = local.rules.isolated_egress
}