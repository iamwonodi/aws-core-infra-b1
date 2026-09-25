# First run: all four repositories, in order

Each repository documents its own setup. This is how they fit together, and the order that matters.

```text
  modules (terraform-aws-*)        tagged releases everything else pins
         |
         v
  core (this repository)           network, edge, compute, database, roles,
         |                          the platform contract
         |  service-roles.json  <── both service repositories ask for a role
         v
  service-infra                    the service's cloud resources
         |  /<project>/services/<service>/config
         v
  application (django)             build, release, deploy
```

**The rule behind the order:** every step reads something the step before it created. Run one out of order and it fails, usually with `AccessDenied` or `ParameterNotFound`.

---

## 0. Your real repositories

The three blueprints are **templates**, not the repositories you run. Each stays generic, with its project values unset, and every real repository is a copy of one:

| Blueprint | Your copy |
| --- | --- |
| the core-infra blueprint (this repository) | `<project>-core-infra` |
| the service-infra blueprint | `<project>-<service>-infra` |
| the service-app blueprint | `<project>-<service>-app` |

On GitHub, use **Use this template** (not fork) for each, then run that repository's init script in **your copy**. Run everything below from the copies. Nothing in this runbook runs from a blueprint.

**Open:** a copy does not receive later improvements to its blueprint. Until there is a way to carry them across, treat the blueprint's changelog as a list of changes to apply by hand.

## 1. Modules

Core pins these tags. `terraform init` fails until they exist.

| Module | Tag | Needed by |
| --- | --- | --- |
| `terraform-aws-autoscaling` | `v3.0.0` | core (shared fleets), service-infra (dedicated hosts) |
| `terraform-aws-rds-instance` | `v1.0.1` | core (staging, production) |
| `terraform-aws-documentdb` | `v1.0.1` | core (staging, production, with `mongodb`) |
| `terraform-aws-nacl-security` | `v1.0.2` | core (every environment) |
| `terraform-aws-profile` | `v1.1.1` | core (fleets, database host, image builder) |
| `terraform-aws-rds-cluster` | `v1.0.0` | nothing yet |

For each: `fmt`, `init -upgrade`, `validate` on the root and `examples/complete`, commit the lock file, push, tag, push the tag.

---

## 2. Core

**Once per repository:**

```bash
scripts/init-project.sh --project acme --region af-south-1 --domain example.org --reviewers alice \
  --staging-engines postgres --production-engines postgres
```

**Per environment, with that environment's AWS credentials:**

```bash
export AWS_PROFILE=<profile-for-development>
aws sts get-caller-identity
scripts/bootstrap-environment.sh development --set-secrets
```

This creates the state bucket and the core role, and sets `TF_AWS_ROLE_ARN` on both GitHub Environments. It is the one apply nobody else reviews: read the plan.

**Then a pull request.** CI plans; merge; CI applies. The first full apply creates everything in that environment.

| Environment | What core's apply creates |
| --- | --- |
| development | VPC, edge, **shared fleets**, the golden image, the platform scripts, the **EC2 database host** |
| staging, production | VPC, edge, the golden image, the platform scripts, the **RDS instance** and its provisioning function, the permissions boundary |

Repeat bootstrap and apply for staging, then production.

**Trap:** the golden image takes 10 to 20 minutes to build on the first apply. The apply waits for it.

---

## 3. A database engine (development only)

The EC2 database host runs whatever the platforms team publishes. **Until an engine is published and registered, no service in development can provision a database.**

1. Publish `database/registry.json` and `database/engines/postgres/` to the deploy bucket.
2. Send `<project>-database-update`.
3. The engine's pipeline publishes its port at `/<project>/database/engines/postgres/port` and opens it on the isolated security group.

Staging and production need none of this: core's apply creates one RDS instance for each engine listed in that environment's `database_engines` (`infrastructure/<env>/terraform.tfvars`). The internal tier (its load balancer, and in development its shared fleet) is off in every environment until `internal_tier_enabled = true` in that environment's `terraform.tfvars`; turn it on before the first internal-tier service is set up there. To pay only for the hours staging is used, set `database_schedule = "working_hours"` in staging's `terraform.tfvars` and adjust `database_working_hours` (default weekends 08:00–19:00 Lagos time). While staging's databases are stopped, deploys there fail their health checks and provisioning fails; start an instance by hand with `aws rds start-db-instance --db-instance-identifier <project>-staging-<engine>` (it stops again at the day's stop time). The list ships empty; set it with `scripts/init-project.sh --staging-engines ... --production-engines ...` before a service there needs a database.

---

## 4. Onboard a service

A service is **two repositories**, and each needs its own role from core.

**In service-infra:**

```bash
scripts/init-service.sh --project acme --service auth --region af-south-1 --port 1024
scripts/print-role-entry.sh          # kind: infra
```

**In the application repository:**

```bash
scripts/init-app.sh --project acme --service auth --region af-south-1
scripts/print-role-entry.sh          # kind: app
```

**In core:** paste **both** entries into `infrastructure/<env>/data/service-roles.json`, for every environment the service will run in, and open a pull request. Both must share `service_name` and `tier`.

**After core applies, in both service repositories:**

```bash
scripts/fetch-role-arn.sh --core OWNER/CORE --environment development
```

**Trap:** `fetch-role-arn.sh` reads core's `platform-outputs` branch, which only exists after core's first apply publishes to it.

---

## 5. service-infra

A pull request, per environment, development first. Its apply creates the ECR repository, the secret, the target group and ALB rule, and — in staging and production — the service's own hosts. Then it provisions the database and publishes `/<project>/services/<service>/config`.

| Environment | Hosts | Database provisioned by |
| --- | --- | --- |
| development | attaches to the tier's shared fleet | SSM document on the EC2 host |
| staging, production | its own ASG, one on-demand plus spot | Lambda on the RDS instance |

**Trap:** the application repository cannot deploy until this has applied, because the config parameter does not exist yet.

---

## 6. The application

Set `RELEASE_TOKEN` (a personal access token that can push tags): tags pushed by the default token start no other workflow, so a release would never build.

Then merge to `main`:

```text
merge  ->  semantic-release tags vX.Y.Z  ->  image built  ->  development deploys itself
```

**Staging and production are deliberate:** run Deploy by hand with the tag. It is refused unless that tag already deployed successfully to the environment below.

---

## People (database logins)

Three levels, each traceable to a person except the last:

- **A service's agents** (`<service>.<name>`, that service's database only): declared in the service's own repository and created whenever it is provisioned. Their passwords are in the service's own secret; the service team hands them over.
- **The platform list** (`platform.<name>`, every service's database): `infrastructure/<env>/data/people.json` in core (see that folder's `README.md`). The apply's last step, *Provision People*, creates the logins; if it was skipped (staging's databases stopped) or failed, run the **Provision people** workflow for that environment. Passwords are in `<project>-database-people-<env>-secret-vault`; hand them over privately.
- **Each engine's administrator**, for emergencies only.

In production a service's agents are read-only unless listed in `infrastructure/production/data/agent-write-exceptions.json`.

**Connection caps:** each service's login, and each person's, may hold only so many connections open at once, set in `infrastructure/<env>/data/connection-limits.json` (see that folder's `README.md`). A service or a person seeing *too many connections for role* (PostgreSQL) or *has exceeded the 'max_user_connections' resource* (MySQL) has reached its own cap, not the engine's: close idle connections (a pool that never releases them, a GUI left open), or raise the number there, or add an exception for that one service, and apply. A service's new cap takes effect when it is next provisioned; the platform list's at the end of core's apply.

**Signing in to the tools** (development and staging): everyone on the platform list, and every agent a service declares, gets a sign-in automatically, and Cognito emails them an invitation. To see or re-run what the front door did, look at (or invoke) the `<project>-<env>-front-door` function; it changes nothing if any declaration is unreadable, and says which.

## If it stops

| Symptom | Usually |
| --- | --- |
| `init`: module not found | a `terraform-aws-*` tag in step 1 was not pushed |
| `sts:AssumeRoleWithWebIdentity` denied | the repository's role entry is missing from core, or core has not applied it, or its IDs are wrong |
| `AccessDenied` creating a resource in service-infra | core's generated policy is missing an action. Paste it: the dedicated policy has never run |
| `ParameterNotFound` for `/platform/config` | core has not applied in this environment |
| `ParameterNotFound` for `/services/<service>/config` | service-infra has not applied in this environment |
| `could not read the database port` | development only: no engine is registered (step 3) |
| provisioning fails | development: the engine is not running. Staging and production: read the function's log, printed in the workflow |
| `no host answered` on deploy | the hosts have not finished booting, or are not tagged `Project`/`Service` as expected |
| a tag was pushed and nothing built | `RELEASE_TOKEN` is missing |

---

## What has never run

Nothing here has been applied to AWS. The steps most likely to need a fix on the first run, in order:

1. core's first apply of the extracted `compute/image` and `compute/deploy-bucket` modules;
2. service-infra's first **dedicated** apply, against core's generated policy and the boundary;
3. the provisioning function's first connection to RDS.

Expect the first run of each to stop once. Paste the error.
