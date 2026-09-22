# The platform contract

Everything a service repository needs to know about the environment it deploys onto is published as **one SSM parameter**:

```text
/<project>/platform/config        (String, JSON)
```

There is no environment segment: each environment is its own AWS account, so the parameter simply exists in that account.

A service reads it with a data source. It never reads core's Terraform state, which holds every secret core generated (database passwords, for one).

```hcl
data "aws_ssm_parameter" "platform" {
  name = "/${var.project_name}/platform/config"
}

locals {
  platform = jsondecode(data.aws_ssm_parameter.platform.value)
  tier     = local.platform.tiers[var.tier]
}

resource "terraform_data" "contract_version" {
  lifecycle {
    precondition {
      condition     = local.platform.schema_version == 1
      error_message = "This service was written for platform contract version 1; core publishes version ${local.platform.schema_version}."
    }
  }
}
```

## Shape (schema_version 1)

```json
{
  "schema_version": 1,
  "project_name": "acme",
  "environment": "development",
  "region": "eu-west-1",
  "account_id": "123456789012",
  "domain_name": "dev.example.org",
  "private_domain": "dev.example.org",
  "vpc_id": "vpc-...",
  "ecr_registry_url": "123456789012.dkr.ecr.eu-west-1.amazonaws.com",
  "buckets": { "deploy": "acme-development-deploy", "assets": "acme-development-assets" },
  "hosting_model": "shared",
  "compute": { "ami_parameter": "/acme/platform/ami/ubuntu", "scripts_manifest_parameter": "/acme/platform/scripts-manifest", "platform_prefix": "_platform" },
  "service_boundary_arn": null,
  "fleet_update_document": "acme-fleet-update",
  "isolated": { "security_group_id": "sg-..." },
  "database": { "host": "db.dev.example.org", "provision_document": "acme-database-provision", "provision_function": null, "update_document": "acme-database-update" },
  "tiers": {
    "private":  { "security_group_id": "sg-...", "alb_security_group_id": "sg-...", "asg_name": "...", "listener_arn": "arn:...", "subnet_ids": null },
    "internal": { "security_group_id": "sg-...", "alb_security_group_id": "sg-...", "asg_name": "...", "listener_arn": "arn:..." }
  }
}
```

| Field | A service uses it to |
| --- | --- |
| `hosting_model` | know whether services run on shared fleets (`shared`, development) or create their own hosts (`dedicated`, staging and production) |
| `service_boundary_arn` | (dedicated only) set as the `permissions_boundary` of every IAM role the infra repository creates, which it may create only under the path `/services/<service>/` and with a `Service` tag |
| `compute.ami_parameter` | (dedicated) read the golden AMI's ID for a launch template. Read the PARAMETER, never copy the ID: core rebuilding the image then reaches you on the next plan |
| `compute.scripts_manifest_parameter`, `compute.platform_prefix` | (dedicated) install core's deploy scripts from `<deploy bucket>/_platform/`, verifying each against the manifest |
| `tiers.<tier>.subnet_ids` | (dedicated) where a service's own hosts go, so no service repository hard-codes the network. Null on a shared fleet |
| `tiers.<tier>.listener_arn` | attach its ALB rule (the rule must carry the tag `Service = <service>`) |
| `tiers.<tier>.asg_name` | attach its target group to the tier's ASG |
| `tiers.<tier>.security_group_id`, `alb_security_group_id` | allow the tier's ALB to reach its service port |
| `buckets.deploy` | publish `<tier>/<service>/docker-compose.yml` and `.env` |
| `buckets.assets` | publish static files under `static/<service>/` (set `STATIC_URL` to `/static/<service>/`) |
| `fleet_update_document` | redeploy: send this SSM document, and nothing else, to the tier's hosts |
| `ecr_registry_url` | name its image `<registry>/<service>/<type>:<tag>` |
| `database.host` | connect to the database host |
| `database.provision_document` | (the service's **infrastructure** repository) create the service's database and user on the EC2 host: publish a request to `provisioning/<service>/` in the deploy bucket, then send this document |
| `database.provision_function` | the same job on a **managed** database: invoke this Lambda with `{"service_name": "<service>"}`. Exactly one of these two is set, never both |
| `database.update_document` | (the platforms team's pipeline, development only) apply the engines it published under `database/` in the deploy bucket. Null on a managed database |

In a `dedicated` environment `buckets.deploy`, `fleet_update_document`, `database` and the tiers' `security_group_id` and `asg_name` are `null`: each service has its own configuration bucket and update document, which its infra repository creates and describes in `/<project>/services/<service>/config`.

## What is deliberately not in it

- **A CloudFront secret header.** Core does not use one: the ALBs are internal and reachable only through the CloudFront VPC origin, so a shared header adds nothing. A service should not condition its ALB rule on one.
- **A database port.** Each engine runs on its native port (5432, 3306, 27017); the platforms team publishes it as `/<project>/database/engines/<engine>/port`; read it with `ssm:GetParameter` on that path. The service role may read `/<project>/database/*`.
- **Secrets of any kind.** Everything here is an identifier.

## Changing the contract

Adding a field is compatible. Renaming or removing a field, or changing its meaning, bumps `schema_version`. The parameter must stay under 4,096 characters (an SSM standard parameter); the module fails the plan if it does not.
