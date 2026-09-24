# tools-role

The CI role for the **team-tools repository**, which runs the team's own tools (the database GUIs, later others) on hosts of their own. Core makes room for them (the `team-tools` security group, the front door, database access); that repository runs them. This module generates the role its pipeline assumes, scoped to exactly that, as `engines-role` does for the platforms team. It grants nothing until `repository` is set.

## What the role may do

| Area | Scope |
| --- | --- |
| Security group, launch template, instances | created only tagged `Service=team-tools`, and managed only when so tagged |
| Auto Scaling group | `<project>-<environment>-team-tools-asg` and its scheduled actions: the schedules, the Start button (desired capacity) and auto-off |
| Instance role and profile | under `/services/team-tools/`, created only with core's permissions boundary, which confines them to the SSM agent and team-tools' own names |
| Load balancer (development, staging) | target groups and rules on the private tier's listener, created only tagged `Service=team-tools` and managed only when so tagged |
| Front door (development, staging) | its app client and the client's managed login style on core's user pool. No user management: who may sign in is the front door's declarations |
| Parameters | the platform contract and the golden AMI parameter |
| State | its own prefix, `team-tools/`, in core's state bucket |

Guard rails deny removing a role's boundary, removing the `Service` tag, and changing the boundary policy. `team-tools` is a reserved service name, so no service can ever share the tag.

**What AWS cannot scope:** creating an app client on the user pool cannot be limited to some clients. A client alone admits no one, but it is why that repository's changes need review.

## Inputs

| Name | Description |
| --- | --- |
| `repository` | `{ name, owner_id, repository_id }`, or null to grant nothing |
| `state_bucket_name`, `state_prefix` | where its state lives (`team-tools` by default) |
| `permissions_boundary_arn` | core's service boundary |
| `ami_parameter_name` | the golden AMI parameter |
| `listener_arn`, `user_pool_arn` | the private listener and the front door's pool; null in production, where the tools have no web address |

## Outputs

| Name | Description |
| --- | --- |
| `service_roles` | to merge into the OIDC module's `service_roles` |
| `policy_size` | the policy's length; IAM allows 10,240 characters, and the module refuses a policy over it (about 9,100 with long names today) |

```bash
terraform init -backend=false && terraform test
```
