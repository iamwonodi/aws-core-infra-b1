################################################################################
# TERRAFORM AWS CLOUDFRONT MODULE
#
# Complete example demonstrating:
#   - Multiple CloudFront origins
#   - Private S3 origin
#   - Automatically created CloudFront Origin Access Control (OAC)
#   - Application Load Balancer custom origin
#   - /static/* routing to S3
#   - /media/* routing to S3
#   - /errors/* routing to S3
#   - Default application routing to ALB
#   - CloudFront custom error responses
#   - HTTPS/custom domain configuration
#   - AWS WAF integration
#   - CloudFront Standard Logging v2
#
# This example intentionally consumes externally managed infrastructure.
# The S3 bucket, ALB, ACM certificate, WAF Web ACL, and logging destination
# are expected to exist outside this example.
################################################################################


resource "random_password" "cloudfront_token" {
  length  = 32
  special = false # Keeps it strictly alphanumeric to prevent HTTP header character issues
}



################################################################################
# CLOUDFRONT DISTRIBUTION
################################################################################

module "cloudfront" {
  source = "git::https://github.com/iamwonodi/terraform-aws-cloudfront.git?ref=v2.0.0"

  ##############################################################################
  # GENERAL CONFIGURATION
  ##############################################################################

  project_name = var.project_name
  environment  = var.environment

  comment = "${var.project_name}-${var.environment} ${var.comment}"

  enabled         = true
  is_ipv6_enabled = true

  http_version = "http2"

  price_class = "PriceClass_100"

  default_root_object = null


  ##############################################################################
  # CUSTOM DOMAIN / HTTPS
  ##############################################################################

  aliases = var.aliases

  # CloudFront ACM certificates must be provisioned in us-east-1.
  acm_certificate_arn = var.acm_certificate_arn

  minimum_protocol_version = "TLSv1.2_2021"


  ##############################################################################
  # AUTOMATIC S3 ORIGIN ACCESS CONTROL
  ##############################################################################

  # The module automatically creates one CloudFront Origin Access Control
  # whenever at least one S3 origin exists.
  #
  # The generated OAC is automatically attached to every S3 origin.
  #
  # The caller therefore does NOT need to provide:
  #
  #   origin_access_control_id
  #
  # and should NOT configure an Origin Access Identity when automatic OAC
  # creation is enabled.
  create_s3_origin_access_control = true


  ##############################################################################
  # ORIGINS
  ##############################################################################

  origins = {

    ##########################################################################
    # PRIVATE S3 ORIGIN
    ##########################################################################
    #
    # This origin contains:
    #
    #   static/*
    #   media/*
    #   errors/*
    #
    # The bucket remains private and CloudFront accesses it through OAC.
    #
    s3 = {
      domain_name = var.s3_origin_domain_name
      origin_type = "s3"
    }


    ##########################################################################
    # APPLICATION LOAD BALANCER ORIGIN (VPC ORIGIN)
    ##########################################################################
    #
    # All requests that do not match an ordered cache behavior are sent here.
    #
    # This ALB is internal -- it has no public IP and is not reachable over
    # the internet. A plain custom origin requires the origin to be publicly
    # reachable, so it cannot work here; a VPC origin lets CloudFront reach
    # a private, non-internet-facing origin instead. alb_vpc_origin_id
    # points at the aws_cloudfront_vpc_origin resource created in the edge
    # domain module, alongside this wrapper.
    #
    alb = {
      domain_name = var.alb_origin_domain_name
      origin_type = "vpc"

      vpc_origin_config = {
        vpc_origin_id = var.alb_vpc_origin_id
      }

      # Custom header to verify requests come through CloudFront
      custom_header = [
        {
          name  = local.cloudfront_header
          value = local.cloudfront_token
        }
      ]
    }
  }


  ##############################################################################
  # DEFAULT CACHE BEHAVIOR
  ##############################################################################
  #
  # The default behavior is the application path.
  #
  # Therefore:
  #
  #   /                     -> ALB
  #   /login/               -> ALB
  #   /api/users            -> ALB
  #   /dashboard/           -> ALB
  #   /anything-else        -> ALB
  #
  # Specialized paths are handled by ordered cache behaviors below.
  #
  default_cache_behavior = {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = [
      "GET",
      "HEAD",
      "OPTIONS",
      "PUT",
      "POST",
      "PATCH",
      "DELETE"
    ]

    cached_methods = [
      "GET",
      "HEAD"
    ]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    response_headers_policy_id = null

    compress = true
  }


  ##############################################################################
  # ORDERED CACHE BEHAVIORS
  ##############################################################################
  #
  # CloudFront evaluates these paths before the default behavior.
  # CloudFront caps ordered_cache_behaviors at 25 per distribution by default
  # Routing:
  #
  #   /static/* -> S3
  #   /media/*  -> S3
  #   /errors/* -> S3
  #   /{appName}/* -> S3
  #   /*        -> ALB
  #
  ordered_cache_behaviors = [
    for key, pattern in local.s3_asset_path_patterns : {
      path_pattern           = pattern
      target_origin_id       = "s3"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]

      cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
      origin_request_policy_id   = null
      response_headers_policy_id = null

      compress = true
    }
  ]

  ##############################################################################
  # CUSTOM ERROR RESPONSES
  ##############################################################################
  #
  # When the application origin returns one of these status codes, CloudFront
  # retrieves the corresponding error page from the S3 origin.
  #
  # Example:
  #
  #   ALB -> 503
  #        -> CloudFront
  #        -> S3 /errors/503/v1/index.html
  #        -> Viewer
  #
  # Only infrastructure failures (502, 503, 504) are mapped. Custom error
  # responses apply to every origin, so mapping 404 or 500 would replace the
  # application's own error pages and JSON error bodies with a generic HTML
  # page. Applications answer their own 404 and 500.
  #
  custom_error_responses = [

    {
      error_code            = 502
      response_code         = 502
      response_page_path    = "/errors/502/v1/index.html"
      error_caching_min_ttl = 10
    },

    {
      error_code            = 503
      response_code         = 503
      response_page_path    = "/errors/503/v1/index.html"
      error_caching_min_ttl = 10
    },

    {
      error_code            = 504
      response_code         = 504
      response_page_path    = "/errors/504/v1/index.html"
      error_caching_min_ttl = 10
    }
  ]


  ##############################################################################
  # ORIGIN GROUPS
  ##############################################################################
  #
  # Disabled in this example.
  #
  # Origin groups are intentionally demonstrated separately from custom error
  # responses because they solve a different problem:
  #
  #   Custom error response -> viewer-facing error page
  #   Origin group          -> origin failover
  #
  origin_groups = {}


  ##############################################################################
  # AWS WAF
  ##############################################################################

  # The WAF Web ACL is externally managed.
  #
  # Set web_acl_id = null when WAF integration is not required.
  web_acl_id = var.web_acl_id


  ##############################################################################
  # STANDARD LOGGING V2
  ##############################################################################
  #
  # The logging destination is externally managed.
  #
  # The module creates:
  #
  #   - CloudWatch Log Delivery Source
  #   - CloudWatch Log Delivery Destination
  #   - CloudWatch Log Delivery
  #
  logging = {
    enabled = var.logging_enabled

    source_name      = var.logging_source_name
    destination_name = var.logging_destination_name

    destination_type = var.logging_destination_type
    destination_arn  = var.logging_destination_arn

    region = var.logging_region

    output_format   = "json"
    field_delimiter = ","

    record_fields = [
      "date",
      "time",
      "x-edge-location",
      "sc-bytes",
      "c-ip",
      "cs-method",
      "cs(Host)",
      "cs-uri-stem",
      "sc-status",
      "cs(Referer)",
      "cs(User-Agent)",
      "cs-uri-query",
      "cs(Cookie)",
      "x-edge-result-type",
      "x-edge-request-id",
      "x-host-header",
      "cs-protocol",
      "time-taken"
    ]

    s3 = {
      suffix_path = "/cloudfront/{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
    }
  }


  ##############################################################################
  # TAGS
  ##############################################################################

  tags = var.tags
}




################################################################################
# S3 BUCKET POLICY RESOURCE
################################################################################

resource "aws_s3_bucket_policy" "cloudfront" {
  bucket = var.s3_bucket_id
  policy = data.aws_iam_policy_document.cloudfront_s3.json

  depends_on = [
    module.cloudfront
  ]
}