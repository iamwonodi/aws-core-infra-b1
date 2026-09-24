# front-door

The Cognito sign-in the team tools' web addresses sit behind (development and staging; production's tools are reached only through a private tunnel), and the function that decides who is in it.

## Who is in it

Everyone declared, and no one else. Declarations are JSON files in the deploy bucket:

| Object | Written by | Holds |
| --- | --- | --- |
| `front-door/<service>.json` | the service's infrastructure repository (its role may write this one object) | its agents' emails |
| `front-door/_platform.json` | this module | the platform list's emails (core's `people.json`) |

Each is `{ "emails": [ ... ] }`. `_platform` can never be a service's name.

Whenever a declaration is created, changed or deleted, S3 invokes the function (`<project>-<environment>-front-door`), which reads **every** declaration and makes the pool's users match their union:

- an email declared anywhere gets exactly one sign-in, however many services declare it; Cognito emails the invitation;
- a sign-in whose email no declaration names is deleted, including a user added to the pool by hand;
- if any declaration cannot be read, is malformed, or `_platform.json` is missing, it changes **nothing** and fails, rather than act on part of the picture.

Invoking the function by hand is always safe: it ignores its event and reconciles everything.

## Why services do not touch Cognito

Permissions on a user pool cannot be limited to some of its users: a role that could add its own people could remove anyone's. So services only declare, each in its own file, and one core function acts.

## The pool

Essentials tier (free up to 10,000 monthly active users; its managed login sets up the authenticator app at first sign-in), sign-in by email, an authenticator app always required, no self sign-up, Cognito's own email sender, deletion protection on. The sign-in domain prefix is `<project>-<environment>-team-<account-id>`, on managed login (version 2).

The tools repository creates the app client (with the tools' web addresses as callback URLs) and its managed login style; until one exists, nobody can sign in anywhere.

## Inputs

| Name | Description |
| --- | --- |
| `project_name`, `environment`, `account_id` | Naming, and the account whose bucket may invoke the function |
| `deploy_bucket_name` | Holds the declarations. **This module owns the bucket's S3 event notifications**: S3 allows one configuration per bucket, so anything else needing events from it must be added here |
| `platform_emails` | The platform list's emails |
| `tags` | Tags for the pool, the function, its role and logs |

## Outputs

| Name | Description |
| --- | --- |
| `front_door` | `user_pool_id`, `user_pool_arn`, `domain`, `declaration_prefix` (published in the contract as `team_front_door`) |
| `function_name` | The reconciling function |

## Tests

```bash
terraform init -backend=false && terraform test   # the module, against mocked AWS
bash lambda/tests/run.sh                          # the function, against fake S3 and Cognito
```
