# ------------------------------------------------------------------------------
# NETWORK ACL RULES, PER TIER AND DIRECTION
#
# Kept here, not inline in the module block, so tests/rules.tftest.hcl can
# check them: an attribute misplaced into another rule is silently dropped by
# the module's map(object(...)) type, and a rule would vanish unseen.
#
# A packet routed through the NAT keeps the internet host's address, so rules
# for internet traffic name the internet (0.0.0.0/0), never the public subnets.
# ------------------------------------------------------------------------------

locals {
  rules = {
    public_ingress = {
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

    public_egress = {
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

    private_ingress = {

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

      # Replies from the internet, through the NAT. A reply keeps the internet
      # host's address (the NAT only relays it), so the source is not the public
      # subnets.
      ephemeral_from_internet = {
        rule_number = 140
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = "0.0.0.0/0"
        from_port   = 1024
        to_port     = 65535
      }
    }

    private_egress = {
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

    internal_ingress = {

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

      # Replies from the internet, through the NAT. A reply keeps the internet
      # host's address (the NAT only relays it), so the source is not the public
      # subnets.
      ephemeral_from_internet = {
        rule_number = 140
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = "0.0.0.0/0"
        from_port   = 1024
        to_port     = 65535
      }
    }

    internal_egress = {


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

      # Requests to the internet, through the NAT: the packet keeps the internet
      # host's address, so the rule names the internet, not the public subnets.
      http_to_internet = {
        rule_number = 150
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = "0.0.0.0/0"
        from_port   = 80
        to_port     = 80
      }

      https_to_internet = {
        rule_number = 160
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = "0.0.0.0/0"
        from_port   = 443
        to_port     = 443
      }
    }

    isolated_ingress = {
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

      # S3's replies to the HTTPS below.
      ephemeral_from_s3 = {
        rule_number = 130
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = "0.0.0.0/0"
        from_port   = 1024
        to_port     = 65535
      }

      # The NAT instance reaching the VPC endpoints (Session Manager) here.
      https_from_public = {
        rule_number = 140
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = var.public_cidr_block
        from_port   = 443
        to_port     = 443
      }
    }

    isolated_egress = {
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

      https_to_s3 = {
        rule_number = 130
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = "0.0.0.0/0"
        from_port   = 443
        to_port     = 443
      }

      # Replies from the VPC endpoints to the NAT instance.
      ephemeral_to_public = {
        rule_number = 140
        protocol    = "tcp"
        rule_action = "allow"
        cidr_block  = var.public_cidr_block
        from_port   = 1024
        to_port     = 65535
      }
    }
  }
}
