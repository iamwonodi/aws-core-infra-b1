# CloudFront Wrapper

A thin wrapper around the published, versioned `terraform-aws-cloudfront` module, adding this project's own opinions on top: which paths route to S3 versus the ALB, the shared-secret header verifying traffic reached the ALB through CloudFront, and (as of this revision) a VPC origin for the ALB instead of a plain custom origin.

Called only from the `edge` domain module, as a sibling (`source = "../cloudfront"`) -- not intended to be called directly from an environment root.

---

## Inputs

| Variable | Purpose |
| --- | --- |
| `project_name` / `environment` | Standard identification |
| `s3_bucket_id` / `s3_bucket_arn` / `s3_origin_domain_name` | The externally managed assets bucket |
| `alb_origin_domain_name` | The ALB's DNS name |
| `alb_vpc_origin_id` | ID of the `aws_cloudfront_vpc_origin` pointed at that ALB -- created by the caller, not this module |
| `aliases` | CloudFront alternate domain names |
| `acm_certificate_arn` | Must be a `us-east-1` certificate |
| `web_acl_id` | Optional WAF association |
| `logging_*` | Optional CloudFront Standard Logging v2 configuration |

## Outputs

| Output | Description |
| --- | --- |
| `id` / `arn` | The CloudFront distribution |
| `domain_name` / `hosted_zone_id` | Needed by any DNS alias record pointing at this distribution |
| `status` | Current deployment status |
| `header` / `token` | The shared-secret header name/value, so the ALB's listener rules can verify a request actually came through CloudFront |
| `s3_oac_id` / `s3_oac_arn` | The automatically created OAC |
| `logging_delivery_source_arn` / `logging_delivery_destination_arn` | Present only when Standard Logging v2 is enabled |

---

## Requirements

* Terraform `>= 1.6.0`
* AWS provider `>= 6.45.0, < 7.0.0` (inherited from the underlying `terraform-aws-cloudfront` module)
