# Platform Scripts Module

The scripts every host runs, kept in one place so the fleets and the database host always agree on them. This module creates **no resources**; it only exposes files and checksums.

| Output | Purpose |
| --- | --- |
| `deploy_lib_path` | Path of `deploy-lib.sh`, uploaded to `_platform/lib/` in the deploy bucket by the module that owns the bucket (`compute`) |
| `deploy_lib_sha256` | Its checksum, recorded in each host's scripts manifest |
| `fetch_scripts_function` | The shell function that downloads and verifies scripts, embedded in user data and in the refresh-scripts SSM documents |

## `deploy-lib.sh`

Sourced by the fleet `update.sh` and the database `update.sh`. It changes no shell options and defines functions only:

| Function | What it does |
| --- | --- |
| `deploy_lock` | Serialises runs (boot, CI and secret rotation can all start an update at once) |
| `deploy_jitter` | Random delay, so a fleet-wide trigger does not restart everything at once |
| `ecr_login` | Docker login to ECR; works whether or not the caller enabled `pipefail` |
| `find_compose_file` | Finds `docker-compose.yml` or `docker-compose.yaml` |
| `resolve_env_file` | Resolves `__FROM_SECRET__` references into a scratch env file; tolerates CRLF, refuses newlines |
| `compose_guard` | Renders a compose file with docker and rejects privileged containers, host namespaces, the Docker socket and bind mounts outside allowed paths |

The compose guard is a **best-effort deny-list, not a security boundary**.

## `fetch_platform_scripts`

Reads a manifest (S3 key to SHA-256) from an SSM parameter, downloads every listed object, and installs them **only if every checksum matches**. Checksums live in SSM rather than user data, so editing a script never changes user data and never restarts a running host.

## Testing

The functions are covered by offline tests that run them against stubbed `aws` and `docker` commands. Those tests cannot prove Docker or AWS behaviour; they prove this module's own logic.
