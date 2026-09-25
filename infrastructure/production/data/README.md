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
| `service_name` | yes | Lowercase letters, digits and hyphens, 3-22 characters. Both of a service's entries use the same one. It names the service's ECR repository, secret, target group and S3 prefixes, so it must be unique. The names `database`, `database-hub`, `fleet`, `internal`, `platform`, `private`, `services` and `team-tools`, and any name beginning `database-`, are reserved |
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

# people.json

**The platform list**: you and anyone you trust platform-wide. Each person gets a login on **every service's database**. **It ships empty (`{}`)**; `people.example.json` shows the shape.

A service team's own members are not listed here: each service declares its **agents** in its own repository, and an agent's login (`<service>.<name>`) reaches only that service's database.

| Field | Required | Meaning |
| --- | --- | --- |
| key | yes | A short name: 2-20 lowercase letters and digits, starting with a letter. Their login is `platform.<name>`, on every engine |
| `email` | yes | Their sign-in, and where their invitation goes. Unique |
| `access` | yes | `read` (look at and query data) or `write` (also add, change and delete rows). `write` is allowed here because this list is itself approved by core's production review. Neither can change tables: that is the services' migrations' job |

**Adding someone:** add their entry and apply. Their database password is generated and kept, with everyone else's on this list, in the secret `<project>-database-people-production-secret-vault` under `platform.<name>`, with their access level. Only administrators read it: open it in the console and hand the person their own password over a private channel. Production has no front door: its tools are reached only through a private tunnel, opened with an AWS sign-in (IAM Identity Center).

**Removing someone:** delete their entry and apply. Their password goes at once, and their logins at the end of the apply.

**When the logins change on the databases:** at the end of every apply, the workflow's *Provision People* step creates, updates and removes the `platform.` logins on every engine to match this file; a service provisioned afterwards is covered at once. The **Provision people** workflow runs that step on its own.

**A new database password for someone:** `terraform apply -replace='module.people.random_password.person["<name>"]'`.

**Emergencies:** each engine's administrator login (`platformadmin`, or the database host's root) can do everything. Keep it for when nothing else will do: its actions are not traceable to a person.

# agent-write-exceptions.json

A service's agents are read-only in production unless core approves them here. **It ships empty (`[]`)**; `agent-write-exceptions.example.json` shows the shape: a list of agent logins, `"<service>.<name>"`.

A service that asks for `write` in production for an agent not listed here fails its provisioning, with a message naming the agent and this file. Adding a line goes through core's production review.

# connection-limits.json

How many connections each login may hold open **at the same moment** on a shared database engine, so that one service, or one person's forgotten tool, cannot use up the engine's total and cut every other service off. The engine itself enforces the number: the connection over the cap is refused at once ("too many connections"), and one opens again as soon as another closes. It is not a rate: it does not slow queries or count connections over time.

| Field | Meaning |
| --- | --- |
| `service_default` | Each service's own login (the one its application uses). Ships as `50` here |
| `person` | Each person's login: every agent (`<service>.<name>`) and everyone on the platform list (`platform.<name>`), each counted separately. Ships as `5` |
| `service_exceptions` | Services core approves to have a different number, `{ "<service_name>": <number> }`. Ships empty (`{}`); `connection-limits.example.json` shows the shape. Adding a line goes through core's review, like any change to this folder |

Every number is a whole number from 1 to 10000. The engine's administrator is never capped: it is the emergency way in, and core's provisioning signs in with it.

**What a service counts against its cap:** every connection its hosts hold, added together, since they all use the same login. Two hosts, each running four workers with one connection, hold eight; a deploy briefly runs old and new containers side by side, so leave room for that.

**Caps are ceilings, not reservations.** This environment's engine is, by default (`database_instance_class`), `db.t4g.medium` (4 GiB): about 400 PostgreSQL connections, about 300 on MySQL. If the caps added together exceed that, services can still crowd each other out when every one is busy at once; the caps only stop any one of them taking it all.

**When a change takes effect:** a service's cap, and its agents', the next time that service is provisioned (its own apply); the platform list's at the end of core's next apply. Lowering a cap disconnects nobody: it refuses new connections over the number. This environment's provisioning functions receive this file's values with core's apply.

**MongoDB (DocumentDB) has no per-login connection limit**, so there the numbers are not enforced.
