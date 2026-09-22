# Decision log

The decisions that shape this blueprint, each with the reason, so a future reader does not have to reconstruct them. Newest concerns last within each group.

## Layout

| Decision | Why |
| --- | --- |
| `modules/` holds four infrastructure domains (network, edge, compute, database) plus `platform/` | The domains mirror the architecture; everything else — who may deploy, the contract, the shared scripts — is not infrastructure and would otherwise flatten that shape into a dozen sibling folders |
| A module used by exactly one domain is nested inside it (`edge/cloudfront`, `network/nacl-security`) | They are that domain's own composition, not a shared building block |
| Moving a module's files does not move anything in state | A resource's address comes from the module **call** name, not its source path |

## Blueprint

| Decision | Why |
| --- | --- |
| Repository name and IDs are variables, supplied by the caller and never committed | Many projects clone this repository; nothing project-specific may be baked in. CI passes them from the GitHub context |
| Values that differ per project ship as `CHANGE_ME`, with format validation and a CI guard | A clone must not reach AWS half-configured, or point at a domain nobody owns |
| One AWS account per environment | Limits any mistake to one environment. So SSM paths and IAM names carry no environment segment; global names (S3 buckets) still do |
| The Terraform version lives in `.terraform-version` only | One place to change; CI and the bootstrap script read it |
| Default assets are this repository's `assets/` folder; an external repository is optional | A clone works without a second repository or a long-lived token |

## Identity and access

| Decision | Why |
| --- | --- |
| Trust GitHub Environment subjects (`<env>`, `<env>-plan`), not branch or pull-request subjects | Every job declares an environment, and then GitHub issues an environment subject; the OIDC module's defaults never matched |
| Immutable subject format (numeric IDs) by default, with a classic switch | A renamed or transferred repository cannot be impersonated by someone who later claims the old name |
| One administrator role per account, guarded by GitHub Environments | A role that creates IAM roles can grant itself anything, so trimming its policy buys little; who can run a job as it is what matters. `<env>-plan` lets plans be guarded separately from applies |
| A service has two repositories, infra and app, and two roles | The repository that creates resources and the one that deploys the application have different jobs; giving each only its own means the app's CI can never create or change a resource, and only the infra role ever holds IAM |
| Service roles are generated from `service_name`, `kind` and `tier`, scoped to that service's own resources | Isolation between services without hand-written policies. What AWS cannot scope is documented in `modules/platform/service-roles/README.md` |
| In staging and production each service creates its own hosts, under a permissions boundary | Per-service compute isolates services and lets staging and production be sized differently from development. Creating an instance role is a privilege-escalation path, so the infra role can only create roles that carry the boundary and a `Service` tag, confined to `/services/<service>/`, and can never remove either |
| The boundary uses `${aws:PrincipalTag/Service}` and lives at `/platform/` | One policy confines every service's instance role to its own resources; the path keeps it out of the namespace services may create policies in |
| The names `database`, `database-hub`, `fleet`, `internal`, `platform`, `private` and `services` are reserved | A name-pattern permission on `<project>-<service>-*` would otherwise reach core's own secret and SSM documents |
| Services redeploy with a custom SSM document, never `AWS-RunShellScript` | Permission to send `AWS-RunShellScript` is root on every host |
| Service roles are a separate instance of the OIDC module | The first apply targets only the core role; anything it depends on is built too, and the service roles depend on the whole environment. A test enforces this |
| Role ARNs are published to a `platform-outputs` branch, not `main` | `main` stays pull-request-only, with no bypass rule and no bot commits |

## Platform

| Decision | Why |
| --- | --- |
| The infra role writes `/<project>/services/<service>/config` and the app role reads it | The only handoff between a service's two repositories; neither needs the other's permissions |
| Services read one SSM parameter, not core's Terraform state | State contains every generated secret; a service role that could read it could read them all |
| No CloudFront secret header | The ALBs are internal, reachable only through the CloudFront VPC origin |
| Static files live under `static/<service>/` in the shared assets bucket | Reuses CloudFront's one `/static/*` behaviour, so onboarding a service never changes CloudFront |
| Only 502, 503 and 504 map to custom error pages | Custom error pages apply to every origin; mapping 404 or 500 would replace applications' own pages and JSON errors |
| The shared fleets do not own their target groups (`manage_traffic_sources = false`, autoscaling v3) | An ASG's target groups are an attribute of the group, so a service attaching its own from its own repository reads as drift here; before v3 the next core apply removed it, taking every service on the tier out of its load balancer |
| Core builds one golden AMI per environment; services never build their own | Patching decides it: a CVE fix is one rebuild rather than one per service, and nothing in a container host varies per service. It also keeps Image Builder, `ec2:CreateImage` and `iam:PassRole` out of every service's policy and out of the boundary |
| The contract carries the AMI parameter's NAME, not the ID | A service's launch template reading the parameter picks up a rebuild on its next plan; an ID copied once would freeze it on whatever was current that day |
| Core owns the deploy scripts for dedicated hosts too | Same argument: a fix to the deploy library is one upload, not one change per service repository. The boundary lets a host read `_platform/` in core's bucket and nothing else in it |
| Shared fleets use EC2 health checks | With ELB checks one failing service makes the group replace a host that runs every co-tenant |
| Database engines are defined by the platforms team; each opens its own port | One engine per type is shared by every service (a database and user each), published on its native port as on RDS. The platforms team decides which engines exist, so core does not open their ports |
| Core owns the provisioning SQL; a service may add an extra file | Every service's database, user and grants are created the same way, and no service writes its own CREATE DATABASE. The extra file runs as the service's own user on its own database: as the administrator, one line of a service's SQL would control every other service's data on that engine |
| Provisioning runs on every apply and is conditional throughout | Terraform triggers it each time, so it must be safe to repeat; setting the password each time is what makes a rotated secret heal itself |
| A service's infra role can send the provisioning document naming another service | IAM cannot condition `ssm:SendCommand` on a parameter's value. It is harmless: it re-runs that service's own published request, which is idempotent |
| Staging and production use an RDS instance, one per engine, shared by every service | An RDS instance runs exactly one engine, chosen at creation; a database per service on one instance matches the development hub and costs a fraction of an instance each |
| Aurora and Multi-AZ DB clusters are not in `terraform-aws-rds-instance` | They are `aws_rds_cluster`, a different resource with different arguments and two endpoints; hiding both behind a `count` would leave half the variables inert in either mode |
| The RDS instance is a published `terraform-aws-rds-instance` module; only the provisioning function stays in core | The instance is generic and any project could use it; the function knows core's service-secret naming and is invoked by core's generated roles, so publishing it would bake platform policy into a reusable building block |
| The published module takes the administrator credential rather than generating one | A module that generates a password owns it, and the caller then has to discover where it went instead of keeping it with its other secrets |
| A managed database is provisioned by a Lambda inside the VPC | There is no container to exec into and no route from a CI runner to the isolated tier. The function derives the secret's name from the service's, so a caller cannot target another service's credential |
| The Lambda's PostgreSQL driver is committed to the repository | The Lambda runtimes carry none, and a compiled one would have to match the runtime's architecture; `pg8000` is pure Python |
| The isolated tier gained a CloudWatch Logs endpoint | It has no route to the internet, so without it anything running there writes no logs at all and a failure is invisible |
| The two provisioning paths are mutually exclusive in the contract | An environment has either an EC2 host with a document or a managed instance with a function, never both; a precondition enforces it |
| An engine stops only on an explicit `active: false` | A database must never stop because a file disappeared |
| Scripts live in S3, verified against an SSM checksum manifest | EC2 caps user data at 16 KB; checksums in SSM mean a script edit never restarts a host |
| The compose guard is a best-effort deny-list, not a security boundary | It stops mistakes, but a team that writes a compose file is still trusted. Real isolation is one host per service (dedicated ASGs in staging and production) |
| Invariants are preconditions, not `check` blocks | A failed `check` only warns and the plan continues |
| Generated secrets use only letters, digits and `-_.` | Characters such as `$` and `#` are corrupted by the env files the values pass through |
| Every environment folder commits its provider lock file, and CI enforces it | `terraform init` writes the lock file locally and nothing complains that it is untracked, so it is easy to leave out. A test step fails when one is missing or does not lock a provider the folder declares, and plan, apply and destroy run `init -lockfile=readonly`, which also refuses a lock file missing a provider only a module declares |

## Naming

| Decision | Why |
| --- | --- |
| Every resource that belongs to a service is `<project>-<environment>-<service>-<resource>`; anything else is `<project>-<environment>-<resource>` | One order, and it is the one 16 of the 18 published modules already use. Two orders disagreeing once produced a real bug: a policy scoped to one order denying a group named in the other |
| Names that never leave the account (SSM documents and parameter paths) omit the environment | The account is the environment; buckets and IAM names include it because they are global or shared across accounts |
| **Exception:** the secret and the target group are `<project>-<service>-<environment>-...` | `terraform-aws-secrets-vault` and `terraform-aws-target-group` v1 name them that way. The order becomes uniform when both release a v2. Until then the exception is one local, `service_first_prefix`, in `service-roles`, and one pattern each in the boundary, the provisioning function and the shared fleet's secret policy |
| `fleet` names only what belongs to the shared fleet (`fleet-update`, the fleet's secret and deploy-read policies) | Artifacts both hosting models use are `platform` or `deploy`: the bucket is `<project>-<environment>-deploy` and the manifest is `/<project>/platform/scripts-manifest`. The old names implied a fleet where dedicated hosts have none |
| The hosting models are `shared` and `dedicated` | The old `shared-fleet` named a mechanism where `dedicated` named an exclusivity, so the pair did not read as a pair. Changed before the contract was first published, so no schema bump |
| Two module folders named `scripts` became `compute/deploy-bucket` and `platform/host-scripts` | Each now says what it is, and no folder shares a name with another |
| "Registry" is always qualified: the **port registry** (the platforms team's repository) and the **ECR registry** (container images) | The unqualified word meant two different things in the same repository |
| The provisioning function grants itself the service's role before creating its database | RDS's administrator is a member of `rds_superuser`, not a true superuser, and PostgreSQL refuses to create or reassign a database to a role its creator cannot become ("must be able to SET ROLE"). Found by running the SQL against a real PostgreSQL as a non-superuser admin; every fake-cursor test had passed |

