# The first real run: what to watch

Everything here has been built and tested offline (mocked AWS, fake command-line tools, real PostgreSQL and MySQL for the database logins), but none of it has run against real AWS. This is what only a real run can prove, across every repository, in the order you meet it. Tick each as it passes; when one fails, the note says where to look.

## 0. Before the first apply

- [ ] Every repository has its pending bundles applied and pushed.
- [ ] Every pinned module version exists on GitHub (checked on 2026-09-25: all 32).
- [ ] `environments.json` (core) and each repository's `.github/environments.json` list the same environments or fewer.

## 1. Core, development first (`docs/first-apply.md`)

- [ ] **The first plan** of a fresh environment: provider arguments, and every `for_each` keyed by names known at plan time (the modules fixed for this were released as nacl-security v1.0.2, profile v1.1.1, rds-instance v1.0.1, documentdb v1.0.1).
- [ ] **The golden image builds** with Docker, Compose, the AWS CLI and Python (staging and production now set them, like development).
- [ ] **The network:** a request through CloudFront reaches a service (the load balancers' outbound rules); the database host is reachable by SSM, fetches its scripts from S3 and pulls from ECR (the isolated tier's outbound rules and network ACL).
- [ ] **The database host** (development) starts, and the engines repository's first deploy runs (section 2).
- [ ] **Staging and production:** RDS and DocumentDB are created; the provisioning functions reach their database and Secrets Manager (they wear the isolated group), verify TLS and authenticate (SCRAM on PostgreSQL). Staging's `working_hours` schedule starts and stops the databases.
- [ ] **The dedicated-hosting policy** (service roles, staging and production) is a first draft: the first service apply may name a missing action. It is close to IAM's 10,240-character limit, so the next additions need a managed policy.
- [ ] **The front door** (development, staging): the Cognito pool exists; writing `front-door/_platform.json` invokes the front-door function (its logs show the reconciliation).
- [ ] **Provision People** (the apply's last step) creates the `platform.` logins on each engine.

## 2. The engines repository (development only)

- [ ] `ec2:AuthorizeSecurityGroupIngress` with a referenced security group and tags works under the engines role, including the rules from the team-tools group.
- [ ] Each engine's healthcheck passes inside `compose up --wait`; MongoDB's first boot (its temporary init server can answer early).
- [ ] A changed administrator password does not reach running engines (known limitation: the images read it only on first boot).

## 3. The first service (`aws-service-infra-b1`)

- [ ] Dedicated hosting (staging, production): the boundary allows what the hosts need; the launch template's `block_device_mappings`; `jq` on the image.
- [ ] Provisioning creates the service's database, then its **agents** (`<service>.<name>`) and brings the **platform list** up to date. On RDS MySQL, the master user may `REVOKE ALL PRIVILEGES, GRANT OPTION` and grant per database (simulated offline with its documented privileges). On DocumentDB, `readAnyDatabase` / `read` roles (offline only).
- [ ] In production, an agent asking for `write` without core's approval stops provisioning with its message.
- [ ] The front-door declaration (`front-door/<service>.json`) gives each agent a sign-in, and Cognito's invitation arrives.
- [ ] A plan in an environment core does not run stops at "Check Core Runs This Environment".

## 4. The app (`django-service-app-b1`)

- [ ] The first release: semantic-release tags it (the commit-message check keeps messages readable to it), the image builds and pushes, and development deploys.
- [ ] Dedicated hosting: the hosts carry `Service=<service>` and answer the service's own document.
- [ ] Promotion: staging (or the next environment listed) accepts only a tag that ran below it.

## 5. The team tools (`aws-team-tools-b1`)

- [ ] **The image tags exist on Docker Hub:** `dbgate/dbgate:7.3.1`, `dbeaver/cloudbeaver:25.3.5` (taken from the projects' release tags; not checked against Docker Hub).
- [ ] **A server starts:** Start tools, then `/var/log/team-tools-start.log`: the RDS bundle's checksum passes, MySQL's truststore is built, both containers run.
- [ ] **The sign-in:** `https://dbgate.<domain>` sends you to Cognito's managed login; a new user sets a password **and an authenticator app** (documented for Essentials; not yet seen for invited users); the load balancer reaches Cognito's token endpoint.
- [ ] **CloudBeaver** configures its administrator from `CB_ADMIN_NAME` / `CB_ADMIN_PASSWORD` (no setup page), shows the prepared connections, and connects to MySQL over TLS with the built truststore.
- [ ] **DbGate** connects to every engine with your own login; **writes to DocumentDB** work (`retryWrites=false` rides in the port field).
- [ ] The schedule starts and stops the server; Start tools books the stop two hours later in UTC.

## 6. The tunnel (`aws-identity-b1`)

- [ ] IAM Identity Center is enabled, and "Send email OTP" is on.
- [ ] `scripts/bootstrap.sh` creates the role; the first Apply creates the users, groups and the `TeamToolsTunnel` assignment.
- [ ] A new person's first sign-in sends the verification email, and they set a password and two-factor sign-in.
- [ ] `aws ssm start-session ... AWS-StartPortForwardingSession` to the tools server works; a shell session (`aws ssm start-session --target ...` with no document) is refused; another instance is refused.
