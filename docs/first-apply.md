# First apply: from a fresh clone to a working pipeline

Each environment is a separate AWS account, so steps 3 and 4 are repeated per environment with that account's credentials.

## 0. Prerequisites

| Tool | Why |
| --- | --- |
| `terraform` at the version in `.terraform-version` | everything, including CI, uses that one file |
| `aws` CLI | the state bucket and the first apply |
| `gh` CLI, authenticated (`gh auth login`) | GitHub Environments and secrets |
| `jq`, `git`, `bash` (Git Bash on Windows) | the scripts |

**The RDS certificate bundle** must be committed at `modules/database/provisioning/lambda/certificates/rds-global-bundle.pem` (download command in the README beside it). The blueprint ships without it, since it must come from AWS itself; staging's and production's plans stop, and CI fails, until it is there. Committing it once in the blueprint gives it to every copy.

The repository must exist on GitHub with an `origin` remote. GitHub Environment protection rules (required reviewers, branch policies) work on public repositories and on private ones with a GitHub Team or Enterprise plan.

## 1. Set the project's values

```bash
scripts/init-project.sh --project acme --region eu-west-1 --domain example.org --reviewers alice,bob \
  --staging-engines postgres --production-engines postgres
```

This writes `project_name`, `aws_region`, the domains and the state bucket into each environment's `terraform.tfvars` and `backend.tf`, and creates the GitHub Environments: each environment and a `-plan` companion, with reviewers required on staging and production. Preview first with `--dry-run`. Commit the result.

**Which environments:** a project runs any one, two or all three. `--environments development,production` (say) writes `environments.json`, which every workflow and script reads: only those are set up, planned, applied, destroyed or provisioned, and the others' folders stay in the repository, ignored. Omitted, the current list is kept (the blueprint lists all three). To add one later, re-run with the longer list, then bootstrap it (step 4). **To retire one, destroy it first** (the destroy workflow acts only on listed environments), then remove it from the list, then remove its state bucket (`scripts/destroy-terraform-backend.sh <environment>`, which still accepts it by name).

Domains: production serves the base domain, staging `staging.<base>`, development `dev.<base>`.

Database engines: `--staging-engines` and `--production-engines` choose, per environment, which engines run, each on its own instance: `postgres` and `mysql` on RDS, `mongodb` on a DocumentDB cluster, any combination (`postgres,mongodb`), or `none`. Every engine is billed while it runs, so list only what a service there uses. Omitted, an environment's list is left as it is, so re-running the script never changes it by accident; to change it later, re-run with the flag or edit `database_engines` in that environment's `terraform.tfvars`. Development's engines come from the database engines repository instead.

## 2. Optional: local configuration

`local-config/` holds templates for values you rarely need (a separate assets repository, an older repository's subject format). Skip it for a default setup.

## 3. Point your credentials at one environment's account

```bash
export AWS_PROFILE=<profile-for-development>
aws sts get-caller-identity          # confirm it is the right account
```

## 4. Bootstrap the environment

```bash
scripts/bootstrap-environment.sh development --set-secrets
```

In order, it:

1. creates the state bucket (`<project>-development-tfstate`) in the region from `terraform.tfvars`, with versioning, encryption and public access blocked;
2. reads this repository's name and numeric IDs from GitHub (never committed);
3. runs `terraform apply -target=module.github_oidc`: **the one apply nobody else reviews**, so read the plan. It creates only the GitHub OIDC provider and the core role. This is safe because that module depends on nothing else; a test enforces it;
4. sets `TF_AWS_ROLE_ARN` on both `development` and `development-plan`.

Repeat steps 3 and 4 for `staging` and `production`.

Terraform variables set outside CI. `terraform validate` needs none. For a local `plan` or `apply`:

```bash
eval "$(scripts/github-identity.sh)"                                   # bash / Git Bash
scripts/github-identity.sh --shell powershell | Invoke-Expression      # PowerShell
```

## 5. From here on, everything goes through pull requests

Open a pull request. `terraform-plan.yml` plans each changed environment under its `-plan` GitHub Environment (approved by a reviewer in staging and production) and comments the plan. Merge to `main`, and `terraform-apply.yml` applies that exact plan under the environment itself.

The first full apply creates the network, edge, fleets and database host. It fails fast, before touching AWS, if any `CHANGE_ME` remains.

## 6. Onboard a service

A service has **two repositories**: `infra` (its Terraform) and `app` (build and deploy).

1. In **each** service repository, run its bootstrap script. It prints a ready-to-paste entry for `service-roles.json`, including that repository's numeric IDs.
2. In **this** repository, add **both** entries (`"kind": "infra"` and `"kind": "app"`, the same `service_name` and `tier`) to `infrastructure/<env>/data/service-roles.json` and open a pull request. `data/README.md` explains each field.
3. After the apply, each repository's role ARN is on the `platform-outputs` branch in `role-arns/<env>.json`.

In staging and production the `infra` role can also create the service's hosts and instance role, capped by the environment's permissions boundary.

## 7. Onboard the platforms team's repository (optional)

Set, in `infrastructure/development/terraform.tfvars`:

```hcl
database_engines_repository          = "OWNER/REPOSITORY"
database_engines_repository_owner_id = "<owner id>"
database_engines_repository_id       = "<repository id>"
```

That grants the repository a role that can publish engines to the deploy bucket, trigger the database update, open each engine's port on the isolated security group and publish it to SSM. Nothing is granted until it is set.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The token subject does not match the trust policy. The repository's IDs may be wrong, or an older repository emits name-only subjects: set `OIDC_SUBJECT_FORMAT=classic` (a variable on the GitHub Environments, and `TF_VAR_oidc_subject_format` locally). If you renamed or transferred the repository, run the bootstrap apply again |
| A plan stops with `CHANGE_ME` | A per-project value was not set. Run `scripts/init-project.sh` |
| `subject_format "immutable" needs the numeric ...` | Provide the IDs: `eval "$(scripts/github-identity.sh)"` |
| `bootstrap-environment.sh` cannot set the secret | The GitHub Environments do not exist yet: run `scripts/init-project.sh` |
| A pull request's plan waits | The `-plan` environment requires a reviewer |
