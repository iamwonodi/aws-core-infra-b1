# Core infrastructure blueprint

A multi-account AWS platform for hosting containerised services, written as a **reusable blueprint**: clone it for a project, run one script to set the project's values, and everything else is code.

Each environment (`development`, `staging`, `production`) is its own AWS account with its own Terraform state. Nothing in this repository is specific to one project; values that differ per project ship as the marker `CHANGE_ME`, and CI refuses to plan while any remain.

```text
                            INTERNET
                                |
                           CloudFront ---- static/, media/, errors/ ----> S3 assets bucket
                                |
                     VPC origin (HTTPS 443)
                                |
        +-----------------------+-----------------------+
        |                                               |
   private ALB                                     internal ALB
        |                                               |
   private fleet (ASG)                            internal fleet (ASG)
   services run as Docker Compose                  services run as Docker Compose
        |                                               |
        +-----------------------+-----------------------+
                                |
                         database host (isolated tier)
                         engines run as Docker Compose, defined by the platforms team
```

## What this repository owns

Four infrastructure domains, and one folder for the things that are not infrastructure.

| Domain | Module | What it does |
| --- | --- | --- |
| Network | `network` | VPC, four subnet tiers, NAT, routing, NACLs, tier security groups |
| Edge | `edge` | DNS, certificates, two ALBs, CloudFront, the assets bucket |
| Compute | `compute` | The private and internal fleets, and their deploy documents |
| Compute | `compute/image` | The golden AMI, published as an SSM parameter. Every environment builds one; services read it |
| Compute | `compute/deploy-bucket` | The deploy bucket and the platform scripts every host installs |
| Database | `database/host` | Development: one host with a persistent volume, running the engines the platforms team publishes |
| Database | `database/provisioning` | Staging and production: creates each service's database and user on the managed instance (the instance itself is the published `terraform-aws-rds-instance`) |

| Platform | Module | What it does |
| --- | --- | --- |
| Identity | `platform/identity`, `platform/service-roles`, `platform/service-boundary`, `platform/engines-role` | Who may deploy: the core role, two scoped roles per service (infra and app), the permissions boundary for roles services create, the platforms team's role |
| Contract | `platform/contract` | The one document a service reads to learn about its environment |
| Shared | `platform/host-scripts` | The scripts every host runs, and their tests |

A service is **two separate repositories**: an infrastructure repository (its Terraform) and an application repository (its image and deploy pipeline). Development runs services on shared tier fleets; staging and production give each service its own hosts.

## Repository layout

```text
infrastructure/<env>/     Terraform for one environment (one AWS account)
  data/service-roles.json   which service repositories may deploy here (ships empty)
modules/
  network/                  the VPC and its tiers
  edge/                     DNS, load balancers, CloudFront
  compute/                  the AMI and the shared fleets
  database/                 host/ (development) and provisioning/ (managed)
  platform/                 not infrastructure: who may deploy, and how
assets/                   files uploaded to the assets bucket (default error pages)
scripts/
  init-project.sh           set a clone's project values and prepare GitHub
  bootstrap-environment.sh  one-time setup of an environment's first role
  github-identity.sh        print this repository's identity for Terraform
  ci/                       scripts the workflows call, with tests
local-config/             templates for values you set once
docs/                     first-apply guide, platform contract, decision log
.github/workflows/        plan, apply, destroy, and the test workflows
.terraform-version        the Terraform version everything uses
```

## Getting started

```bash
scripts/init-project.sh --project acme --region eu-west-1 --domain example.org --reviewers alice,bob \
  --staging-engines postgres --production-engines postgres
```

then follow [docs/first-apply.md](docs/first-apply.md). To bring up a service end to end across all four repositories, follow [docs/runbook.md](docs/runbook.md). It covers each environment's account, the one local apply, and the normal pull-request flow afterwards.

## How changes reach AWS

1. **Pull request.** `terraform-plan.yml` plans each changed environment under its `<env>-plan` GitHub Environment and comments the plan.
2. **Merge to `main`.** `terraform-apply.yml` applies exactly the plan that was reviewed, under the `<env>` GitHub Environment, and publishes the role ARNs to the `platform-outputs` branch.

AWS trusts GitHub only through OIDC, and only for those environments. **The safety of the core role comes from the GitHub Environments that guard it** (required reviewers, deployments only from `main`), not from a trimmed policy: a role that creates IAM roles can grant itself anything. `scripts/init-project.sh` sets these up. See [docs/decisions.md](docs/decisions.md).

## Testing

| What | How |
| --- | --- |
| Terraform modules that need no AWS | `terraform test` in `modules/platform/identity`, `service-roles`, `service-boundary`, `platform-contract`, `database-engines-role`; `bash modules/network/tests/run.sh` |
| Host scripts (fleet, database, shared library) | `bash modules/platform/host-scripts/tests/run-all.sh` |
| CI helper scripts | `bash scripts/ci/tests/run-all.sh` |
| Bootstrap stays independent | `python3 scripts/ci/check-bootstrap-closure.py infrastructure/*` |

The script tests run against stubbed `aws`, `docker` and `gh`. They prove the scripts' own logic, not AWS's or Docker's behaviour, and they run in CI. `terraform validate` and `plan` need your AWS accounts.

## Destroying an environment

`terraform-destroy.yml` is manual, requires typing the environment name (or `DESTROY-ALL-ENVIRONMENTS`), and destroys everything in that environment's state, **including its OIDC role**. The state bucket is created outside Terraform and is never touched by it; only `scripts/destroy-terraform-backend.sh` can remove it, by hand, and it refuses while the state still tracks resources.
