# Edge Domain Module

This module is everything that gets a request from the public internet to your application, and everything DNS-related along the way: the assets bucket, CloudFront, both Application Load Balancers, Route 53, and ACM certificates.

If you're new to this repo: think of this module as answering **"how does a request actually arrive, and where does it go first?"** What happens once a request reaches the compute fleets lives in the `compute` module; this module only cares about getting a request there.

---

## The traffic path, in order

```text
Viewer
  |
  v
CloudFront  <-- serves /static, /media, /errors directly from S3
  |
  | VPC origin (not a public custom origin -- see below)
  v
Private-tier ALB (internal, no public IP)
  |
  v
Private-tier fleet (in the compute domain module)
  |
  | backend API calls internal services directly
  v
Internal-tier ALB (internal, reached only from the private tier)
  |
  v
Internal-tier fleet (in the compute domain module)
```

---

## Why the private-tier ALB needs a VPC origin, not a plain custom origin

This is the one piece of this module that's easy to get wrong, so it's worth explaining directly.

CloudFront's traditional "custom origin" type requires the origin to be reachable over the **public internet** -- CloudFront's edge locations sit outside any VPC and connect to custom origins over the public internet, full stop. The private-tier ALB here is deliberately `internal = true` -- it has no public IP at all. Those two facts are simply incompatible: a custom origin pointed at an internal ALB cannot work, no matter how the security group is configured.

The fix is a **VPC origin** (`aws_cloudfront_vpc_origin`), a distinct CloudFront feature that lets it reach a private, non-internet-facing origin directly through your VPC. This module creates that resource and passes its ID into the `cloudfront` wrapper, which uses `origin_type = "vpc"` instead of `"custom"` for the ALB origin.

**The security group rule didn't need to change.** It's tempting to assume VPC origins need a different security-group approach than custom origins, but AWS's own guidance confirms the CloudFront managed prefix list restriction (`private_alb_sg_ingress_rule`, allowing port 443 from `com.amazonaws.global.cloudfront.origin-facing`) remains correct for VPC origins too -- it isn't specific to custom origins. So that rule is unchanged from before this fix.

---

## What this module creates

### Assets bucket + S3 origin

A private S3 bucket (no public access, `BucketOwnerEnforced`) holding static assets, served through CloudFront rather than directly. `force_destroy` and how long noncurrent object versions are retained are both caller-configurable -- deliberately, since these should differ per environment: development churns fastest and has the least need for historical retention, while staging deliberately mirrors production's stricter settings (staging exists specifically to rehearse what production will actually do -- if it silently allowed the same data loss production is protected against, it would stop being a reliable rehearsal).

### Route 53 hosted zones

A public zone (`domain_name`) and a private zone (`private_domain`), which may be the **same real domain name** -- this is split-horizon DNS, a standard, valid Route 53 pattern where the private zone (associated with your VPC) takes priority for resolvers inside the VPC, while the public zone answers everyone else. `public`/`private` here are logical labels this module uses internally, not the real DNS names themselves.

### ACM certificates

Two certificates: one specifically for CloudFront (which AWS requires to be issued in `us-east-1`, regardless of what region the rest of this environment runs in), and one for everything else (issued in your actual `aws_region`).

### Both Application Load Balancers

The private-tier ALB (CloudFront's origin, as described above) and the internal-tier ALB (reached only from the private tier's own security group -- never directly from CloudFront or the internet).

### CloudFront

Delegates to the `cloudfront` wrapper module (a sibling of this one), which itself wraps the published, versioned `terraform-aws-cloudfront` module. Routes `/static/*`, `/media/*`, `/errors/*` straight to S3; everything else goes to the private-tier ALB.

### DNS records

Public records (root, `www`, wildcard) pointing at CloudFront, and a private wildcard record pointing at the internal-tier ALB, for internal service-to-service resolution.

---

## Inputs this module needs from elsewhere

This module owns no VPC/subnet/security-group resources of its own. Five inputs come from the `network` domain module's outputs:

| Input | From `network` output |
| --- | --- |
| `vpc_id` | `vpc_id` -- used to associate the private hosted zone |
| `private_subnet_ids` | `private_subnet_ids` -- where the private-tier ALB lives |
| `internal_subnet_ids` | `internal_subnet_ids` -- where the internal-tier ALB lives |
| `private_security_group_id` | `private_security_group_id` -- allowed to reach the internal-tier ALB |

---

## What this module hands back

| Output | Used by |
| --- | --- |
| `private_zone_id` | The `data` domain module -- the database's IAM Route 53 permissions and its private DNS registration both need this |
| `distribution_id` / `distribution_domain_name` | Whatever needs to reference the CloudFront distribution directly |
| `assets_bucket_id` / `assets_bucket_arn` | Same, for the assets bucket |
| `private_alb_security_group_id` / `internal_alb_security_group_id` | The `platform-contract` module, so a service can allow its tier's ALB to reach its service port |

---

## On `validations.tf`

This module doesn't have one. Every correctness constraint here is single-variable (a domain name isn't empty, a subnet list isn't empty) and already enforced inline in `variables.tf`, where Terraform requires `validation` blocks to live. Unlike the `compute` module, there wasn't a genuine cross-variable invariant worth a `check` block here -- adding an empty or manufactured one would just be ceremony.

---

## Requirements

* Terraform `>= 1.6.0`
* AWS provider `>= 6.0, < 7.0`

---

## Module Structure

```text
edge/
├── main.tf         -- assets bucket, route53, acm, both ALBs, VPC origin, cloudfront, DNS records
├── variables.tf     -- every input, each with inline validation
├── locals.tf        -- naming, CloudFront aliases, the S3 content-type map
├── data.tf          -- the CloudFront origin-facing prefix list lookup
├── outputs.tf
└── README.md
```

Calls `../cloudfront` (the CloudFront wrapper, a sibling module) internally.
