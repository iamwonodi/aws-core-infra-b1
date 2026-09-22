# Service Permissions Boundary Module

Builds the IAM **permissions boundary** for the roles a service creates. It creates no resources; the caller creates the policy from `policy_json`, so the module can be tested without AWS.

## Why

In a `dedicated` environment (staging, production) a service's infrastructure repository creates its own hosts, and therefore an IAM role for them. A role that can create roles could create one more powerful than itself. So the infrastructure role may only create roles that carry this boundary. A boundary is a **ceiling**: whatever is attached to such a role, its effective permissions are the intersection with this policy. Even `AdministratorAccess` attached to a service's instance role grants nothing beyond what is listed here.

## How it confines each service to its own resources

The policy names no service. It uses the policy variable `${aws:PrincipalTag/Service}`. Every role a service creates must be tagged `Service=<service>` (the infrastructure role's policy requires it and forbids removing the tag), so the one policy confines each instance role to **its own** secret, configuration bucket, image repository and parameters.

## What it allows, and denies

| Allows | Scoped to |
| --- | --- |
| The SSM agent (so a deploy can reach the host) | the agent's own actions |
| Pull images | `repository/<service>/*` |
| Read the service's secret | `<project>-<service>-<env>-secret-vault-*` |
| Read the service's configuration bucket | `<project>-<env>-<service>-config` |
| Read published parameters | `/<project>/platform/*` and `/<project>/services/<service>/*` |

It **denies** all of IAM (`iam:*`) and role assumption (`sts:AssumeRole*`), so an instance role can neither widen its reach nor pivot to another role.

The policy lives at the IAM path `/platform/`, never under `/services/`, so no name a service controls can match it. Managed databases will need `rds-db:connect` added here.

## Outputs

`policy_name`, `policy_path`, `policy_json`, and `policy_arn` (the ARN the policy will have once created, which the infrastructure role's policy requires roles to carry). Run the tests with `terraform test`.
