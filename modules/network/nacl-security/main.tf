module "nacl_security" {
  source = "git::https://github.com/iamwonodi/terraform-aws-nacl-security.git?ref=v1.0.1"

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

  public_ingress_rules = {
    http_from_private = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 80
      to_port     = 80
    }

    https_from_private = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 443
      to_port     = 443
    }

    http_from_internal = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 80
      to_port     = 80
    }

    https_from_internal = {
      rule_number = 130
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 443
      to_port     = 443
    }

    ephemeral_from_internet = {
      rule_number = 140
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = "0.0.0.0/0"
      from_port   = 1024
      to_port     = 65535
    }
  }

  public_egress_rules = {
    http_to_internet = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = "0.0.0.0/0"
      from_port   = 80
      to_port     = 80
    }

    https_to_internet = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = "0.0.0.0/0"
      from_port   = 443
      to_port     = 443
    }

    ephemeral_to_private = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    ephemeral_to_internal = {
      rule_number = 130
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 1024
      to_port     = 65535
    }
  }

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

  private_ingress_rules = {
    ephemeral_from_public = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.public_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    tcp_from_internal = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    ephemeral_from_isolated = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.isolated_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    tcp_from_private = {
      rule_number = 130
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 0
      to_port     = 65535
    }
  }

  private_egress_rules = {
    tcp_to_public = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.public_cidr_block
      from_port   = 80
      to_port     = 443
    }

    tcp_to_internal = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    tcp_to_isolated = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.isolated_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    ephemeral_to_cloudfront = {
      rule_number = 130
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = "0.0.0.0/0"
      from_port   = 1024
      to_port     = 65535
    }

    http_to_internet = {
      rule_number = 140
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = "0.0.0.0/0"
      from_port   = 80
      to_port     = 80
    }

    https_to_internet = {
      rule_number = 150
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = "0.0.0.0/0"
      from_port   = 443
      to_port     = 443
    }
  }

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

  internal_ingress_rules = {
    ephemeral_from_public = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.public_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    tcp_from_private = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    tcp_from_internal = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    ephemeral_from_isolated = {
      rule_number = 130
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.isolated_cidr_block
      from_port   = 1024
      to_port     = 65535
    }
  }

  internal_egress_rules = {
    http_to_public = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.public_cidr_block
      from_port   = 80
      to_port     = 80
    }

    https_to_public = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.public_cidr_block
      from_port   = 443
      to_port     = 443
    }

    ephemeral_to_private = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    tcp_to_internal = {
      rule_number = 130
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    tcp_to_isolated = {
      rule_number = 140
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.isolated_cidr_block
      from_port   = 0
      to_port     = 65535
    }
  }

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
  # ============================================================================

  isolated_ingress_rules = {
    tcp_from_private = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    tcp_from_internal = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 0
      to_port     = 65535
    }

    tcp_from_isolated = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.isolated_cidr_block
      from_port   = 0
      to_port     = 65535
    }
  }

  isolated_egress_rules = {
    ephemeral_to_private = {
      rule_number = 100
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.private_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    ephemeral_to_internal = {
      rule_number = 110
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.internal_cidr_block
      from_port   = 1024
      to_port     = 65535
    }

    tcp_to_isolated = {
      rule_number = 120
      protocol    = "tcp"
      rule_action = "allow"
      cidr_block  = var.isolated_cidr_block
      from_port   = 0
      to_port     = 65535
    }
  }
}