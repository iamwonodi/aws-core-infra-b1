# people

**The platform list**: the people who get a database login on **every** service's database, `platform.<name>`, from `infrastructure/<env>/data/people.json`. A service's own agents are not here: each service declares them in its own repository, and they reach only its database.

For each person it generates a password and keeps every password and access level of the environment in **one** secret, `<project>-database-people-<environment>-secret-vault`:

```json
{ "platform.<name>": { "password": "...", "access": "read" | "write" } }
```

The secret always exists (empty when nobody is listed, which tells provisioning to remove every `platform.` login). Only administrators read it and hand each person their own password. The logins themselves are created by the provisioning path: the database host's `provision-people.sh` in development, each engine's provisioning function in staging and production.

The list's emails (`emails` output) are declared to the front door (`modules/platform/front-door`).

## Inputs

| Name | Description |
| --- | --- |
| `project_name`, `environment` | Naming |
| `people` | `{ name = { email, access } }`: name 2-20 lowercase letters and digits starting with a letter; email unique; access `read` or `write` |
| `read_only` | Refuse `write` for everyone on this list |
| `tags` | Tags for the secret |

## Outputs

| Name | Description |
| --- | --- |
| `usernames` | name to `platform.<name>` |
| `access` | login to access level |
| `secret_arn` | the people secret |
| `emails` | every person's email, lower case |

To give someone a new password: `terraform apply -replace='module.people.random_password.person["<name>"]'`.
