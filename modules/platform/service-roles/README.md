# Service Roles Module

Turns the entries of `service-roles.json` into the OIDC module's `service_roles` input: for each **repository**, the token subjects to trust (see `github-identity`) and a **generated, scoped inline policy**.

## Two roles per service

A service has two repositories with different jobs, so each gets a role that can do only its own job:

| `kind` | Job | Holds |
| --- | --- | --- |
| `infra` | the repository holding the service's Terraform | Terraform-scale permissions over the service's own resources; in a dedicated environment, IAM limited by a permissions boundary |
| `app` | builds and deploys the application | push an image, publish files, trigger a redeploy. Nothing that creates or changes a resource, and no IAM |

They find each other through one SSM parameter, `/<project>/services/<service>/config`, which the infra role writes and the app role reads.

## Hosting models

| `hosting_model` | Where | Services run |
| --- | --- | --- |
| `shared` | development | on the shared tier fleets. No IAM is granted to any service |
| `dedicated` | staging, production | each service's infra repository creates its own launch template, ASG, security group, configuration bucket and instance role |

## The policies

The policy is built from the service's name and tier, so every resource it names carries that service's own name.

| Purpose | Role | Scoped to |
| --- | --- | --- |
| Push image | app | ECR `repository/<service>/*` |
| Create the repository | infra | ECR `repository/<service>/*` |
| Secret | infra | `<project>-<service>-<env>-secret-vault-*` |
| Target group | infra | `targetgroup/<project>-<service>-<env>-tg/*` |
| ALB rule | infra | the tier's listener; rules must carry `Service=<service>` |
| Publish config | app | shared: deploy bucket `<tier>/<service>/*`; dedicated: `<project>-<env>-<service>-config` |
| Publish static files | app | assets bucket `static/<service>/*` |
| Redeploy | app | shared: the fleet-update document on the tier's hosts; dedicated: `<project>-<service>-update` on the service's hosts |
| Read the contract and service config | app | `/<project>/platform/*`, `/<project>/database/*`, `/<project>/services/<service>/*` |
| Write the service config | infra | `/<project>/services/<service>/*` |
| Terraform state | infra | state bucket `services/<service>/*` |
| Publish its provisioning request | infra (shared) | deploy bucket `provisioning/<service>/*` |
| Create its database | infra (shared) | `<project>-database-provision`, on the database host only |
| Attach to the shared ASG, open a port | infra (shared) | the tier's ASG and security group |
| Own hosts, security group, bucket, update document | infra (dedicated) | names and `Service` tags of that service; the ASG as `terraform-aws-autoscaling` names it, `<project>-<env>-<service>-asg` |
| Instance role and profile | infra (dedicated) | IAM path `/services/<service>/`, only with the boundary and the `Service` tag |

### The permissions boundary

In a dedicated environment the infra role can create IAM roles, which would otherwise be a way to make a role more powerful than itself. Three guards prevent it, and none can be overridden by an Allow:

- A role can only be created with (or given) the environment's boundary, and only with a `Service` tag equal to the service's name.
- The boundary cannot be removed from a role, the `Service` tag cannot be removed, and the boundary policy itself cannot be edited.
- IAM permissions never reach outside the service's own path, `/services/<service>/`.

See the `service-boundary` module for what the boundary itself allows.

## What AWS cannot scope

- `ecr:GetAuthorizationToken` and the read-only `Describe*` calls need `*`.
- **Shared fleet:** the shared tier security group can be changed by any service's infra role, and AWS cannot limit which port or source a rule opens. Any target group can be detached from the shared ASG. Rely on pull request review.
- **Dedicated:** launch-template and security-group ARNs contain no name, so they are scoped by the `Service` tag instead.
- A service's infra role may send the provisioning document naming a *different* service. `ssm:SendCommand` cannot be conditioned on a parameter's value. It re-runs that service's own published request, which is idempotent, so nothing is gained by it.

ALB rules are protected: a rule can only be created with, and later changed while it carries, a `Service` tag equal to the service's name. The infra repository's `alb-rule` module call must pass `tags = { Service = <service> }` or its plan fails with an access error (fail closed).

## Invariants (hard failures)

Repository keys are `OWNER/REPOSITORY`; `kind` is `app` or `infra`; `service_name` is 3-22 lowercase letters, digits or hyphens and short enough that the generated target group name fits 32 characters; the names the platform itself uses (`database`, `database-hub`, `fleet`, `internal`, `platform`, `private`, `services`) are reserved, because a name-pattern permission would otherwise reach core's own resources; a service has at most one entry of each kind and both must name the same tier; every tier exists; the bucket and document inputs are set; and a dedicated environment with an infra entry has the boundary.

## Size

Each policy must stay under IAM's 10,240-character limit for a role's inline policies. `policy_sizes` reports it: about 2,300 for an app role, 4,900 for a shared infra role and **9,700 for a dedicated infra role**. A precondition fails the plan if any policy exceeds the limit, rather than letting IAM reject the apply. The dedicated one has little headroom; the next statements added to it will have to go into managed policies instead (each at most 6,144 characters).

**The dedicated policy is a first draft.** It covers resources whose creation has not yet been exercised against AWS. Its first real plan is the test; expect to add an action or two. Managed databases are not covered yet.
