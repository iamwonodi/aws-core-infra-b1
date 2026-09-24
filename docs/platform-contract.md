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
  "service_boundary_arn": "arn:aws:iam::<account>:policy/platform/<project>-service-boundary",
  "fleet_update_document": "acme-fleet-update",
  "isolated": { "security_group_id": "sg-..." },
  "tools": { "security_group_id": "sg-...", "subnet_ids": ["subnet-...", "subnet-..."] },
  "team_front_door": { "user_pool_id": "af-south-1_...", "user_pool_arn": "arn:aws:cognito-idp:...", "domain": "<project>-<env>-team-<account>", "declaration_prefix": "front-door/" },
  "database": { "host": "db.dev.example.org", "provision_document": "acme-database-provision", "provision_function": null, "update_document": "acme-database-update", "engines": {} },
  "tiers": {
    "private":  { "security_group_id": "sg-...", "alb_security_group_id": "sg-...", "asg_name": "...", "listener_arn": "arn:...", "subnet_ids": null },
    "internal": { "security_group_id": "sg-...", "alb_security_group_id": "sg-...", "asg_name": "...", "listener_arn": "arn:..." }
  }
}
```

| Field | A service uses it to |
| --- | --- |
| `hosting_model` | know whether services run on shared fleets (`shared`, development) or create their own hosts (`dedicated`, staging and production) |
| `service_boundary_arn` | the permissions boundary every IAM role created outside core must carry: a dedicated service's instance role, and in every environment the team tools' |
| `compute.ami_parameter` | (dedicated) read the golden AMI's ID for a launch template. Read the PARAMETER, never copy the ID: core rebuilding the image then reaches you on the next plan |
| `compute.scripts_manifest_parameter`, `compute.platform_prefix` | (dedicated) install core's deploy scripts from `<deploy bucket>/_platform/`, verifying each against the manifest |
| `tiers.<tier>.subnet_ids` | (dedicated) where a service's own hosts go, so no service repository hard-codes the network. Null on a shared fleet |
| `tiers.<tier>.listener_arn` | attach its ALB rule (the rule must carry the tag `Service = <service>`) |
| `tiers.<tier>.asg_name` | attach its target group to the tier's ASG |
| `tiers.<tier>.security_group_id` | the tier's own security group, which the databases and the Secrets Manager (and, in development, every other) VPC endpoint admit. On a shared fleet, open the service port on it for the tier's ALB. With dedicated hosting, put it on the service's own hosts as well as their own group, or they can reach neither their database nor their secret. It opens nothing on the hosts: it has no inbound rules of its own |
| `tiers.<tier>.alb_security_group_id` | allow the tier's ALB to reach its service port |
| `buckets.deploy` | publish `<tier>/<service>/docker-compose.yml` and `.env` |
| `buckets.assets` | publish static files under `static/<service>/` (set `STATIC_URL` to `/static/<service>/`) |
| `fleet_update_document` | redeploy: send this SSM document, and nothing else, to the tier's hosts |
| `ecr_registry_url` | name its image `<registry>/<service>/<type>:<tag>` |
| `database.host` | connect to the database host |
| `database.provision_document` | (the service's **infrastructure** repository) create the service's database and user on the EC2 host: publish a request to `provisioning/<service>/` in the deploy bucket, then send this document |
| `database.provision_function` | the same job on a **managed** database: invoke this Lambda with `{"service_name": "<service>"}`. Exactly one of these two is set, never both. With several engines, `database.host` and this field describe PostgreSQL; use `database.engines` |
| `database.engines` | (managed databases, staging and production) every active engine, by name: `{"postgres": {"host", "port", "provision_function"}, "mysql": {...}}`. A service connects to its engine's `host` and `port` and provisions through its `provision_function`, which is null while the function does not yet speak that engine. A MongoDB service (DocumentDB) authenticates with `authSource=admin`, over TLS, with `retryWrites=false`; development's MongoDB accepts the same. Empty in development |
| `database.update_document` | (the platforms team's pipeline, development only) apply the engines it published under `database/` in the deploy bucket. Null on a managed database |
| `tools.security_group_id`, `tools.subnet_ids` | (the team-tools repository, not services) the group the team's own tools hosts wear, which the databases, the database host's engine ports (opened by the platforms team's pipeline) and the VPC endpoints admit, and the private subnets those hosts go in. Like the tier groups it has no inbound rules. The platforms team's pipeline opens each engine's port to it as well as to the tiers |
| `team_front_door` | the Cognito user pool the team tools' web addresses sit behind, its sign-in domain prefix (`https://<domain>.auth.<region>.amazoncognito.com`), and `declaration_prefix`. **A service** declares its agents' emails as `<declaration_prefix><service>.json` in the deploy bucket, `{ "emails": [ ... ] }`, the one object there its role may write; core's function turns every declaration into sign-ins. **The tools repository** creates its app client and managed login style on the pool and puts an `authenticate-cognito` action in front of its load balancer rules. Null in production, whose tools are reached only through a tunnel |

In a `dedicated` environment `fleet_update_document`, `database.provision_document`, `database.update_document` and the tiers' `asg_name` are `null`: each service has its own configuration bucket and update document, which its infra repository creates and describes in `/<project>/services/<service>/config`. `buckets.deploy` is still set there, because the service's hosts install core's scripts from its `_platform/` prefix.

## What is deliberately not in it

- **A CloudFront secret header.** Core does not use one: the ALBs are internal and reachable only through the CloudFront VPC origin, so a shared header adds nothing. A service should not condition its ALB rule on one.
- **A database port.** Each engine runs on its native port (5432, 3306, 27017); the platforms team publishes it as `/<project>/database/engines/<engine>/port`; read it with `ssm:GetParameter` on that path. The service role may read `/<project>/database/*`.
- **Secrets of any kind.** Everything here is an identifier.

## Changing the contract

Adding a field is compatible. Renaming or removing a field, or changing its meaning, bumps `schema_version`. The parameter must stay under 4,096 characters (an SSM standard parameter); the module fails the plan if it does not.
