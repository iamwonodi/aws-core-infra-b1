# Compute Domain Module

This module is the compute layer of the core infrastructure blueprint. It builds one shared Ubuntu AMI, two Auto Scaling fleets that run it, and the deployment mechanism those fleets use to actually run team-provided applications.

If you're new to this repo: think of this module as answering one question -- **"what actually runs the application?"** Everything about networking (the VPC, subnets, security groups) lives in the `network` module. Everything about how traffic reaches these fleets (the load balancers, CloudFront, DNS) lives in the `edge` module. This module only cares about the compute itself: the machine image, the two groups of servers that run it, and how those servers get and run each team's own container.

---

## What this module creates

### 1. One shared Ubuntu AMI

Both fleets below run the exact same machine image, built once here rather than separately per fleet. This guarantees they never drift apart in base OS version or installed software -- if you enable Docker, both fleets get Docker; if you don't, neither does.

Building the AMI is itself a small pipeline:
- `ubuntu_ami_profile` -- the IAM role/instance profile the *build process itself* needs (not the fleets -- this is scoped only to what AWS Image Builder needs while constructing the AMI).
- `ubuntu_ami` -- the actual AMI build: takes your parent Ubuntu image, installs whatever software you've toggled on, and produces a new AMI ID.

### 2. The private-tier fleet

This fleet runs your user-facing application: the frontend, the backend API (which itself forwards certain requests on to the internal-tier fleet), and a DB GUI client for administering the database.

**How traffic reaches it:** CloudFront (in front of everything) forwards requests to an ALB that lives in the private subnet. That ALB is *internal* -- it has no public IP of its own. CloudFront is the only public-facing entry point; nothing about this fleet or its ALB is directly reachable from the internet. (See the `edge` module's README for why that ALB needs a CloudFront *VPC origin* specifically, not a plain custom origin.)

Three resources make up this fleet, following the same three-piece pattern every fleet in this project uses:
- `private_profile` -- the IAM role/instance profile the *running instances* use (distinct from the AMI build's own profile above).
- `private_launch_template` -- the instance configuration: which AMI, which IAM profile, which security group, what user-data script runs on boot.
- `private_autoscaling_group` -- the actual fleet: how many instances, where they scale between, which subnets they live in.

### 3. The internal-tier fleet

This fleet runs your stateless internal applications (payment, notifications, and others). It's never reached directly by CloudFront or the public internet; only the private tier's backend API talks to it.

Same three-piece pattern as the private fleet: `internal_profile`, `internal_launch_template`, `internal_autoscaling_group`.

### 4. The fleet deploy bucket and deployment mechanism

This is what actually gets a team's application running on these fleets. Full detail below -- this is the newest and most involved part of this module, worth its own section.

---

## How a service actually gets deployed -- the full mechanism

### The core idea

Fleets have no bounded set of possible applications -- any team can run any containerized app. So there is no compiler here. **Each team provides their own `docker-compose.yml` and `.env` directly.** This module's job is distribution, secret resolution and a safety check, not generation. The database host works the same way (see the `database` module): the platforms team provides a compose file per engine.

### Why S3, not EBS

An EBS volume attaches to one instance at a time -- right for the database's single-host storage, wrong here: every fleet instance (including ones from a future scale-out) must read the *identical* set of files. S3 is shared and multi-reader by nature. The fleet deploy bucket holds every team's files, and every instance syncs its tier's files down before deploying.

### One shared bucket, one directory per service

The private and internal fleets run different applications, so each tier syncs -- and its IAM role may only read -- its own prefix:

```text
private/<service>/docker-compose.yml      (or docker-compose.yaml)
private/<service>/.env
private/<service>/data/**                  (optional seed material)

internal/<service>/docker-compose.yml
internal/<service>/.env

_platform/lib/deploy-lib.sh                (shared scripts; not synced into services)
_platform/fleet/update.sh
```

Which prefix is "its own" comes from `FLEET_TIER` in the instance's rendered `.env`. Each service runs with its own directory as the Compose project directory, so `./data` and `.resolved/.env` resolve inside that service's directory.

**Presence is the only "active" signal.** A service is deployed when its directory holds a compose file and a `.env`, and is stopped on the next sync after the directory is removed.

### What runs where

Terraform uploads the two platform scripts to `_platform/` and publishes their SHA-256 values in an SSM parameter, `/<project>/platform/scripts-manifest`. The instance's user data is small: it installs the runtime `.env`, downloads the scripts, verifies every file against the manifest (installing nothing unless all match), and runs `update.sh`. Because the checksums live in SSM rather than in user data, editing a script never changes user data and never restarts a host. To update scripts on hosts that are already running, send the `<project>-fleet-refresh-scripts` SSM document.

`update.sh` does, in order: take a lock (boot, CI and rotation can all start it at once), wait a random jitter, log in to ECR, sync the tier prefix, stop services whose directory disappeared, then for each service: resolve secrets, run the compose guard, `docker compose up --wait`, and delete the scratch env file.

### Triggering a deploy

Use the `<project>-fleet-update` SSM document, not `AWS-RunShellScript`. The document can only run `update.sh`, so permission to send it is not permission to run arbitrary commands as root. It takes one parameter, `jitterSeconds` (0-999, default 0): CI passes 0, the rotation rule passes 60.

### Secrets -- the `__FROM_SECRET__` convention

A service's `.env` can hold plain values and can reference secrets without ever containing one:

```env
LOG_LEVEL=info
APP_SECRET_ARN=arn:aws:secretsmanager:af-south-1:123456789012:secret:core-auth-development-secret-vault-AbC123

DJANGO_SECRET_KEY=__FROM_SECRET__:APP_SECRET_ARN
DATABASE_PASSWORD=__FROM_SECRET__:APP_SECRET_ARN:db_password
```

The ARN-holding variable can be named anything; the sentinel says which one to use. With no third segment, the lookup key is the variable name **lowercased** (`DJANGO_SECRET_KEY` looks up `django_secret_key`); a third segment names the field explicitly, which is needed when the variable name and the field name differ. Windows line endings are tolerated. A value containing a newline is refused. A service with no sentinels skips resolution.

Generated secrets in this project use only letters, digits and `-_.`, because characters like `$` and `#` are meaningful in the env files these values pass through.

**Which secrets a host may read.** Hosts may read secrets named by the vault module's scheme, `<project>-<service>-<environment>-secret-vault`. The database hub's own secret follows the same scheme and is explicitly **denied**: it holds the database administrator credential, which only the database host may read.

### Getting a secret rotation picked up

Resolving a secret at deploy time only helps if something triggers a deploy when it changes. This module uses the native `Secret Label Updated` EventBridge event (delivered directly, enabled for every secret), matched on the `AWSCURRENT` label moving -- a manual update or an automatic rotation alike -- and on the secret's name:

```text
<project>-*-<environment>-secret-vault
```

That is the name the vault module gives every secret, so no naming rule is needed. When it fires, the rule sends the `fleet-update` document with a 60-second jitter to every instance tagged with this project, environment and one of the two fleet names (the database host carries the same project and environment tags but is not targeted). Hosts restart the affected container at staggered moments, so a service is not down everywhere at once. It also fires when a secret is first created; that run is harmless.

Rotating a *database* credential is a two-step operation: the database itself must learn the new password (`provision.sh`) before the secret changes, or the restarted application will hold a password the database does not know.

### The compose guard

Teams write their own compose files and the fleet runs them through Docker as root, so before deploying a service `update.sh` renders its compose file with `docker compose config` and rejects privileged containers, added capabilities, devices, the host network / PID / IPC / UTS / user / cgroup namespaces, unconfined security options, the Docker socket, and any bind mount outside the service's own directory. A rejected service is reported and skipped; the others still deploy.

**This is a best-effort deny-list, not a security boundary.** It stops mistakes and casual abuse, but a team that can write a compose file is still trusted. Real isolation is one host per service, which is what staging and production give each application (a dedicated ASG). Treat the shared fleets as development infrastructure for trusted teams.

### Why the permanent file is never modified with real values

Overwriting a sentinel with its resolved value would destroy the platform's only way of knowing the field needs re-resolving on the next rotation. Instead `update.sh` resolves into a scratch copy at `<service>/.resolved/.env`, points that service's `docker compose up` at it, and deletes it immediately after. A real secret exists on disk only as long as one `up` needs it.

### Isolation between services

Each service runs as its own Compose project (`--project-name <service>`). Compose creates a shared network only *within* one project, so services cannot reach each other by default.

### The instance-side layout

```text
/opt/applications/
├── .env              -- platform-level env (rendered by env.tftpl)
├── update.sh         -- the deploy engine, downloaded and verified at boot
├── deploy-lib.sh     -- shared lock / jitter / ECR login / secrets / compose guard
└── services/
    └── <service>/
        ├── docker-compose.yml, .env    -- synced from S3
        ├── data/                       -- optional seed material, synced from S3
        └── .resolved/                  -- scratch, exists only during a deploy
```

---

---

## Inputs this module needs from elsewhere

This module owns no networking of its own. Four inputs come from the `network` domain module's outputs:

| Input | From `network` output |
| --- | --- |
| `private_subnet_ids` | `private_subnet_ids` |
| `internal_subnet_ids` | `internal_subnet_ids` |
| `private_security_group_id` | `private_security_group_id` |
| `internal_security_group_id` | `internal_security_group_id` |

`internal_subnet_ids` is used twice: once (in full) as where the internal-tier fleet lives, and once (just its first entry) as the temporary subnet the AMI build process launches its build instance into.

There is no external `user_data` input anymore -- this module renders its own bootstrap script internally (`assets/bootstrap.sh` and `assets/update.sh`), matching how the `database` domain module does.

---

## What this module hands back

| Output | Used by |
| --- | --- |
| `ami_id` | The `database` domain module, so the database host runs the same base image as both fleets |
| `private_asg_name` / `private_asg_arn` | Whatever needs to reference the private fleet directly (monitoring, scaling policies you add later) |
| `internal_asg_name` / `internal_asg_arn` | Same, for the internal fleet |
| `deploy_bucket_name` / `deploy_bucket_arn` | The `database` module (scripts and engine definitions) and, through `service_platform`, service repositories |
| `fleet_update_document_name` | Whoever triggers a fleet deploy (CI, the rotation rule) |
| `fleet_refresh_scripts_document_name` | Operators, to refresh scripts on running hosts |

---

## Fleet capacity

Each fleet's `min_size` / `desired_capacity` / `max_size` are independently configurable:

```hcl
private_fleet_min_size         = 1  # default
private_fleet_desired_capacity = 1  # default
private_fleet_max_size         = 2  # default

internal_fleet_min_size         = 1  # default
internal_fleet_desired_capacity = 1  # default
internal_fleet_max_size         = 2  # default
```

Both fleets default to identical values, but there's no requirement they stay that way -- if internal-tier services genuinely need different scaling behavior than the user-facing tier, only that fleet's three variables need to change.

`validations.tf` checks that each fleet's three values are in the right order (`min <= desired <= max`) and stops the plan with an error naming which fleet is wrong (a precondition, so it is not just a warning), before the request reaches the underlying Auto Scaling module.

---

## Ubuntu AMI configuration reference

| Variable | What it controls |
| --- | --- |
| `ubuntu_parent_image` | The starting AMI both fleets' image is built from |
| `ami_description` | Description attached to the resulting AMI |
| `enable_predefined_packages` / `enable_docker` / `enable_aws_cli` / `enable_python` | Software toggles -- see the `terraform-aws-ubuntu-ami` module's own README for exactly what each installs |
| `custom_build_commands` / `custom_validate_commands` | Anything beyond the toggles above -- your own install/verification steps |
| `component_version` / `recipe_version` | Image Builder versioning, semantic version form (`X.Y.Z`) |
| `root_volume_size` / `root_volume_type` | The resulting AMI's root volume |
| `ami_instance_types` | Instance types Image Builder may use *while building* -- unrelated to what instance types the fleets themselves run on |
| `build_image` | Whether to actually trigger a build on this apply, or just keep the Image Builder configuration in place without building |
| `ami_build_trigger` | Change this value to force a rebuild without changing anything else |
| `enable_pipeline` / `pipeline_schedule` | An optional recurring rebuild schedule, instead of (or alongside) manual triggers |
| `enable_image_tests` / `image_test_timeout_minutes` | Image Builder's own post-build validation |
| `deploy_bucket_force_destroy` | Whether the deploy bucket can be destroyed while it still holds team files -- matches the same per-environment reasoning as the `edge` module's `assets_force_destroy`; development sets this true, staging/production should not |

---

## Requirements

* Terraform `>= 1.6.0`
* AWS provider `>= 6.0, < 7.0`

---

## Module Structure

```text
compute/
├── main.tf          -- the AMI build, both fleets, the deploy bucket, the platform scripts and their SSM manifest,
│                       the fleet-update and refresh SSM documents, IAM policies, the secret-rotation rule
├── variables.tf      -- every input, each with inline validation
├── validations.tf    -- cross-variable invariants (fleet capacity ordering), enforced as preconditions
├── locals.tf         -- naming, script keys and manifest, the rendered env and user data
├── data.tf           -- lookups and the IAM policy documents
├── outputs.tf
├── assets/
│   ├── env.tftpl        -- platform-level runtime env template
│   ├── bootstrap.sh     -- fleet instance user data (small: installs the env, fetches and verifies scripts)
│   └── update.sh        -- the deploy engine (uploaded to S3, downloaded at boot)
└── README.md
```

The shared library (`deploy-lib.sh`) and the checksum-verified download function live in the `platform-scripts` module, which this module and the `database` module both use.
