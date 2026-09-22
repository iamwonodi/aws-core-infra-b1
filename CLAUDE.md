# Working on this repository

This is a **blueprint**: many projects clone it. Never commit anything project-specific (repository names or IDs, domains, account IDs). Per-project values ship as `CHANGE_ME`.

## Ground rules

- **Never run `terraform plan` or `terraform apply`**, or any AWS-mutating command, unless asked in that specific request. `terraform fmt` and `terraform validate` are fine.
- Read the real files, and the modules a file calls, before proposing a change; defects here have lived in the seam between two files that each looked right. Verify against provider documentation rather than recalling.
- Classify review findings CRITICAL / HIGH / MEDIUM / LOW / OPTIONAL, say PASS when something is correct, and do not rewrite working code for style.
- Comments explain why, not what. Scripts are exercised against real inputs and their error paths before they are called done.
- Keep the smallest change that is correct. Do not add variables or features without a use case.

## Layout

`modules/` holds the four infrastructure domains — `network`, `edge`, `compute` (`image/` for the golden AMI and `deploy-bucket/`, both used by every environment), `database` (`host/` for development, `provisioning/` for the managed instance) — and `platform/`, which holds what is not infrastructure: `identity`, `service-roles`, `service-boundary`, `engines-role`, `contract` and `host-scripts`. A module used by exactly one domain is nested inside it (`edge/cloudfront`, `network/nacl-security`).

## Architecture in one paragraph

Each environment is its own AWS account. `network` builds the VPC and tiers, `edge` the DNS, ALBs, CloudFront and assets bucket, `compute` two shared fleets (private and internal) plus the deploy bucket and deploy engine, `database` one database host. Services deploy by publishing `<tier>/<service>/docker-compose.yml` and `.env` to the deploy bucket and sending the fleet-update SSM document. Everything a service needs to know is in the SSM parameter `/<project>/platform/config` ([docs/platform-contract.md](docs/platform-contract.md)). The decision log is [docs/decisions.md](docs/decisions.md).

## Conventions

- Terraform `>= 1.6.0`; AWS provider `>= 6.0.0, < 7.0.0`. The version CI uses is `.terraform-version`.
- Cross-variable invariants are `terraform_data` preconditions, never `check` blocks (a failed check only warns).
- Modules that need no AWS have `terraform test` suites. Host scripts have offline tests against stubbed `aws`/`docker`/`gh`.
- SSM paths carry no environment segment. S3 bucket names do.
- Generated secrets use only letters, digits and `-_.`.
- Commits are conventional (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`), and the tree stays `terraform fmt` clean.

## Checks before a commit

```bash
terraform fmt -recursive
terraform -chdir=infrastructure/<env> init -backend=false && terraform -chdir=infrastructure/<env> validate
bash modules/platform/host-scripts/tests/run-all.sh
bash scripts/ci/tests/run-all.sh
bash modules/network/tests/run.sh
(cd modules/platform/<module> && terraform init -backend=false && terraform test)     # identity, service-roles, service-boundary, contract, engines-role
bash modules/database/provisioning/lambda/tests/run.sh
python3 scripts/ci/check-bootstrap-closure.py infrastructure/*
```

## Open items

- `terraform-aws-autoscaling` v3.0.0 must be tagged before core can init: the shared fleets pin it. It stops the group reverting target groups attached from a service's own repository.
- The dedicated-hosting policy (staging and production) is a first draft that has never been exercised against AWS; the first real plan will show any missing action. It is 9.6 KB of a 10.2 KB limit, so the next statements added to it will need managed policies.
- Managed-database provisioning (`database/provisioning`, a VPC Lambda) is tested offline and against a local PostgreSQL; TLS and SCRAM against real RDS are unverified.
- Staging and production declare every engine and run only those in their `database_engines`. MySQL instances can be created, but the provisioning function speaks PostgreSQL only, so `database.engines.mysql.provision_function` is null until it learns MySQL. `mongodb` is refused until a DocumentDB module exists.
- Nothing here has been applied to real AWS. The first apply will validate what offline tests cannot: provider arguments, IAM condition keys, and the Docker and AWS behaviour the script tests stub.
- Every `infrastructure/<env>/.terraform.lock.hcl` is committed, locked for every platform (`terraform providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64`). CI fails without it, and every environment init is `-lockfile=readonly`: after adding a provider or a module that brings one, re-lock and commit before pushing.
- Names: `<project>-<environment>-<service>-<resource>` for anything with a service, `<project>-<environment>-<resource>` otherwise; SSM documents and parameter paths omit the environment. The secret and the target group are the one exception (`<project>-<service>-<environment>-...`, from `secrets-vault` and `target-group` v1): keep them behind `service_first_prefix` in `service-roles` until both modules release a v2. `fleet` names only the shared fleet's own things; `shared` and `dedicated` are the hosting models. Always say **port registry** or **ECR registry**, never "the registry".

