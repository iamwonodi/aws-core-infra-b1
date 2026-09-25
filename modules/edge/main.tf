########################################################################################
# ASSETS BUCKET & CLOUDFRONT S3 ORIGIN
#
# force_destroy and the noncurrent-version expiration window are both
# caller-configurable (see variables.tf) specifically because they should
# differ per environment: development churns fastest and has the least
# need for historical retention, while staging deliberately mirrors
# production's stricter settings, since staging exists to rehearse what
# production will actually do.
########################################################################################

module "assets_bucket" {
  source = "git::https://github.com/iamwonodi/terraform-aws-s3.git?ref=v1.0.0"

  bucket_name = "${var.project_name}-${var.environment}-assets"

  force_destroy      = var.assets_force_destroy
  versioning_enabled = true

  object_ownership = "BucketOwnerEnforced"

  block_public_access = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }

  encryption = {
    type = "SSE-S3"
  }

  lifecycle_rules = [
    {
      id = "expire-noncurrent-versions"
      noncurrent_version_expiration = {
        noncurrent_days = var.assets_noncurrent_version_expiration_days
      }
    },
    {
      id = "abort-incomplete-multipart-uploads"
      abort_incomplete_multipart_upload = {
        days_after_initiation = 7
      }
    }
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
    Purpose     = "${var.project_name}-assets"
  }
}

resource "aws_s3_object" "remote_assets" {
  for_each = local.assets

  bucket = module.assets_bucket.bucket_id

  key    = each.value
  source = "${var.assets_path}/${each.value}"

  etag = filemd5("${var.assets_path}/${each.value}")

  content_type = lookup(
    local.content_types,
    lower(regex("\\.[^.]+$", each.value)),
    "application/octet-stream"
  )
}

########################################################################################
# ROUTE 53 HOSTED ZONES
#
# public and private are logical labels, not the real DNS names -- see
# domain_name and private_domain in variables.tf for why they can safely
# share the identical real domain name (split-horizon DNS).
########################################################################################

module "route53" {
  source = "git::https://github.com/iamwonodi/terraform-aws-route53-hosted-zone.git?ref=v2.0.0"

  project_name = var.project_name
  environment  = var.environment

  hosted_zones = {
    public = {
      domain_name = var.domain_name
      zone_type   = "public"
    }

    private = {
      domain_name = var.private_domain
      zone_type   = "private"

      vpc_associations = [
        { vpc_id = var.vpc_id }
      ]
    }
  }

  tags = {
    Owner = "Infrastructure"
  }
}

########################################################################################
# ACM CERTIFICATES
########################################################################################

module "acm" {
  source = "git::https://github.com/iamwonodi/terraform-aws-acm.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment

  certificates = {
    # CloudFront requires its viewer certificate to be issued in us-east-1,
    # regardless of which region the rest of this environment runs in.
    cloudfront = {
      region      = "us-east-1"
      domain_name = var.domain_name

      subject_alternative_names = [
        "www.${var.domain_name}",
        "*.${var.domain_name}"
      ]

      validation_method = "DNS"

      # PUBLIC Route 53 zone
      route53_zone_id = module.route53.zone_ids["public"]

      wait_for_validation = true

      key_algorithm = "RSA_2048"
    }

    default = {
      region      = var.aws_region
      domain_name = var.domain_name

      subject_alternative_names = [
        "www.${var.domain_name}",
        "*.${var.domain_name}"
      ]

      validation_method = "DNS"

      # PUBLIC Route 53 zone
      route53_zone_id = module.route53.zone_ids["public"]

      wait_for_validation = true

      key_algorithm = "RSA_2048"
    }
  }
}

########################################################################################
# PRIVATE-TIER ALB
#
# This is CloudFront's application origin. It is internal (not
# internet-facing) -- CloudFront reaches it through a VPC origin below,
# not a plain custom origin, since a custom origin requires the origin to
# be reachable over the public internet.
########################################################################################

module "private_alb_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = var.vpc_id
  sg_name      = local.private_alb_name
  description  = local.private_alb_sg_description
}

# CloudFront -> Private ALB HTTPS ingress. AWS confirms this same
# prefix-list restriction remains correct for a VPC origin, not just a
# custom origin -- see data.tf.
module "private_alb_sg_ingress_rule" {
  source = "git::https://github.com/iamwonodi/terraform-aws-sg-ingress-rule.git?ref=v1.2.1"

  security_group_id = module.private_alb_sg.security_group_id
  description       = "Allow HTTPS from CloudFront origin-facing servers"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

# A load balancer opens connections of its own: to its targets (every request
# and health check) and, for a rule with a sign-in step, to the identity
# provider's token endpoint on the internet (through NAT). Terraform removes
# AWS's default allow-all outbound rule when it creates a security group, so
# without this rule the load balancer could reach nothing at all.
module "private_alb_sg_egress_rule" {
  source = "git::https://github.com/iamwonodi/terraform-aws-sg-egress-rule.git?ref=v2.0.0"

  security_group_id = module.private_alb_sg.security_group_id
  description       = "Allow the load balancer to reach its targets and identity provider"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

module "private_alb" {
  source = "git::https://github.com/iamwonodi/terraform-aws-load-balancer.git?ref=v1.0.0"

  project_name = "${var.project_name}-${local.private_alb_name}"
  environment  = var.environment
  internal     = true

  subnet_ids            = var.private_subnet_ids
  alb_security_group_id = module.private_alb_sg.security_group_id
  acm_certificate_arn   = module.acm.certificate_arns["default"]

  default_target_group_arn = null
}

########################################################################################
# INTERNAL-TIER ALB
#
# Reached only from the private tier's own backend API -- never from
# CloudFront or the internet directly.
#
# Created only while internal_tier_enabled is on: a load balancer is billed
# every hour, whether or not a service sits behind it.
########################################################################################

module "internal_alb_sg" {
  source = "git::https://github.com/iamwonodi/terraform-aws-security-group.git?ref=v1.0.0"
  count  = var.internal_tier_enabled ? 1 : 0

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = var.vpc_id
  sg_name      = local.internal_alb_name
  description  = local.internal_alb_sg_description
}

# PRIVATE -> INTERNAL ALB firewall configuration.
module "internal_alb_sg_ingress_rule" {
  source = "git::https://github.com/iamwonodi/terraform-aws-sg-ingress-rule.git?ref=v1.2.1"
  count  = var.internal_tier_enabled ? 1 : 0

  security_group_id            = module.internal_alb_sg[0].security_group_id
  description                  = "Allow HTTPS from private application workloads"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.private_security_group_id
}

# As for the private load balancer: without an outbound rule it could reach
# none of its targets.
module "internal_alb_sg_egress_rule" {
  source = "git::https://github.com/iamwonodi/terraform-aws-sg-egress-rule.git?ref=v2.0.0"
  count  = var.internal_tier_enabled ? 1 : 0

  security_group_id = module.internal_alb_sg[0].security_group_id
  description       = "Allow the load balancer to reach its targets"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

module "internal_alb" {
  source = "git::https://github.com/iamwonodi/terraform-aws-load-balancer.git?ref=v1.0.0"
  count  = var.internal_tier_enabled ? 1 : 0

  project_name = "${var.project_name}-${local.internal_alb_name}"
  environment  = var.environment
  internal     = true

  subnet_ids            = var.internal_subnet_ids
  alb_security_group_id = module.internal_alb_sg[0].security_group_id
  acm_certificate_arn   = module.acm.certificate_arns["default"]

  default_target_group_arn = null
}

########################################################################################
# CLOUDFRONT VPC ORIGIN
#
# Lets CloudFront reach the private-tier ALB directly through the VPC,
# without the ALB ever needing a public IP.
########################################################################################

resource "aws_cloudfront_vpc_origin" "private_alb" {
  vpc_origin_endpoint_config {
    name                   = "${var.project_name}-${var.environment}-private-alb-vpc-origin"
    arn                    = module.private_alb.alb_arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

########################################################################################
# CLOUDFRONT
########################################################################################

module "cloudfront" {
  source = "./cloudfront"

  project_name = var.project_name
  environment  = var.environment

  s3_bucket_id          = module.assets_bucket.bucket_id
  s3_bucket_arn         = module.assets_bucket.bucket_arn
  s3_origin_domain_name = module.assets_bucket.bucket_regional_domain_name

  alb_origin_domain_name = module.private_alb.alb_dns_name
  alb_vpc_origin_id      = aws_cloudfront_vpc_origin.private_alb.id

  aliases = local.cloudfront_aliases

  acm_certificate_arn = module.acm.certificate_arns["cloudfront"]
}

# -----------------------------------------------------------------------------
# Route 53 Records
# -----------------------------------------------------------------------------
# Creates the application's public and private DNS records.
# -----------------------------------------------------------------------------

module "route53_public_records" {
  source = "git::https://github.com/iamwonodi/terraform-aws-route53-record.git?ref=v1.0.0"

  records = {
    root = {
      zone_id = module.route53.zone_ids["public"]
      name    = var.domain_name
      type    = "A"

      alias = {
        name                   = module.cloudfront.domain_name
        zone_id                = module.cloudfront.hosted_zone_id
        evaluate_target_health = false
      }
    }

    www = {
      zone_id = module.route53.zone_ids["public"]
      name    = "www.${var.domain_name}"
      type    = "CNAME"

      records = [
        var.domain_name
      ]
    }

    wildcard = {
      zone_id = module.route53.zone_ids["public"]
      name    = "*.${var.domain_name}"
      type    = "A"

      alias = {
        name                   = module.cloudfront.domain_name
        zone_id                = module.cloudfront.hosted_zone_id
        evaluate_target_health = false
      }
    }
  }
}

# The private wildcard points at the internal-tier load balancer, so it exists
# only with it.
module "route53_private_records" {
  source = "git::https://github.com/iamwonodi/terraform-aws-route53-record.git?ref=v1.0.0"
  count  = var.internal_tier_enabled ? 1 : 0

  records = {
    wildcard = {
      zone_id = module.route53.zone_ids["private"]
      name    = "*.${var.private_domain}"
      type    = "A"

      alias = {
        name                   = module.internal_alb[0].alb_dns_name
        zone_id                = module.internal_alb[0].alb_zone_id
        evaluate_target_health = true
      }
    }
  }
}
