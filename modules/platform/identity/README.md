# GitHub Identity Module

Turns a repository and a GitHub Environment into the OIDC token subjects AWS should trust. Creates no infrastructure.

## Why it exists

Every workflow job that touches AWS declares a GitHub Environment. GitHub then issues its token with an **environment subject** (`repo:OWNER/REPO:environment:NAME`) instead of a branch or pull-request subject, so the default subjects of the OIDC module never match these workflows.

Two environments are trusted per stage:

| Environment | Used by | Typical GitHub protection |
| --- | --- | --- |
| `<env>` | the job that changes the live environment (apply, destroy) | reviewers, deployments from `main` only |
| `<env>-plan` | plan jobs on pull requests | reviewers in staging and production |

## Subject formats

| Format | Subject | When |
| --- | --- | --- |
| `immutable` (default) | `repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:NAME` | repositories created, renamed or transferred on or after 15 July 2026 |
| `classic` | `repo:OWNER/REPO:environment:NAME` | older repositories |

The immutable form embeds the numeric IDs, so a renamed or transferred repository cannot be impersonated by someone who later claims the old name. Read the IDs with `gh api repos/OWNER/REPO --jq '[.owner.id, .id]'`. A missing or non-numeric ID in immutable mode stops the plan with that command in the message.

## Inputs and outputs

| Input | Default | Meaning |
| --- | --- | --- |
| `github_repository` | required | `OWNER/REPOSITORY` |
| `github_owner_id`, `github_repository_id` | `null` | numeric IDs, required in immutable mode |
| `subject_format` | `immutable` | `immutable` or `classic` |
| `environment` | required | e.g. `development`; must not already end in `-plan` |

| Output | Meaning |
| --- | --- |
| `identifier` | the repository as it appears in a subject |
| `oidc_subjects` | the two subjects to trust |
