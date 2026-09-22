# service-roles.json

One entry per **repository** that deploys onto this environment. **It ships empty (`{}`)**; nothing is granted until you add entries. `service-roles.example.json` shows the shape (JSON has no comments, so it is explained here).

A service has **two repositories with different jobs**, so it gets **two entries** and two roles:

| `kind` | The repository | Its role can |
| --- | --- | --- |
| `infra` | holds the service's Terraform | create and change the service's cloud resources, including its hosts and the IAM role they run as (capped by a permissions boundary) |
| `app` | builds and deploys the application | push an image, publish files, trigger a redeploy. It cannot create or change any resource, and has no IAM permission |

| Field | Required | Meaning |
| --- | --- | --- |
| key | yes | The repository, `OWNER/REPOSITORY` |
| `service_name` | yes | Lowercase letters, digits and hyphens, 3-22 characters. Both of a service's entries use the same one. It names the service's ECR repository, secret, target group and S3 prefixes, so it must be unique. The names `database`, `database-hub`, `fleet`, `internal`, `platform`, `private` and `services` are reserved |
| `kind` | yes | `infra` or `app` |
| `tier` | yes | `private` or `internal`: which ALB and subnets the service uses. Both entries of a service must agree |
| `owner_id`, `repository_id` | when the subject format is `immutable` (the default) | The numeric GitHub IDs of the owner and of **that** repository |
| `description` | no | Shown on the IAM role |

Each repository's bootstrap script prints a ready-to-paste entry, IDs included. To read the IDs by hand:

```text
gh api repos/OWNER/REPOSITORY --jq '{owner_id: (.owner.id|tostring), repository_id: (.id|tostring)}'
```

## How the two repositories find each other

The `infra` role writes one SSM parameter, `/<project>/services/<service>/config`, holding what the app needs (its secret ARN, bucket, and so on). The `app` role reads it. Neither ever needs the other's permissions.

## What an entry grants

A role for that repository, trusted from its `<environment>` and `<environment>-plan` GitHub Environments, with a policy **generated from `service_name`, `kind` and `tier`** by `modules/platform/service-roles`. Every resource it names carries that service's own name. See that module's README for the full table and for what AWS cannot scope.

Services here are **dedicated**: each service creates its own launch template, ASG, security group, configuration bucket and instance role. The `infra` role may create IAM roles only when they carry the environment's permissions boundary (`/platform/<project>-service-boundary`) and a `Service` tag, only under the path `/services/<service>/`, and it can never remove either. That boundary is what stops a service creating a role more powerful than itself.
