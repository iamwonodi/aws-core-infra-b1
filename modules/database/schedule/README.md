# Database Schedule Module

Starts RDS instances on chosen days at a set time and stops them again, so an environment pays only for the hours it is used. Staging uses it when `database_schedule = "working_hours"`; production does not.

| Schedule | When |
| --- | --- |
| `<project>-<env>-<engine>-start` | on each of `days`, at `start` |
| `<project>-<env>-<engine>-stop` | **every** day, at `stop` |

The stop runs every day so that an instance started by hand, or restarted by AWS (it restarts an instance that has been stopped for 7 days), is stopped again that evening.

EventBridge Scheduler calls RDS directly, with no Lambda, through a role that may only start and stop these instances. Starting a running instance or stopping a stopped one is refused by RDS and logged as a failed invocation; nothing is retried.

**Only the instance-hours stop.** Storage and backups are billed either way. While the instances are stopped, services cannot reach their databases: their deploys fail health checks and their provisioning fails.

| Input | Default | Meaning |
| --- | --- | --- |
| `instances` | — | the instances, by engine: `{ id, arn }` |
| `days` | `["SAT", "SUN"]` | days they start (MON ... SUN) |
| `start`, `stop` | `08:00`, `19:00` | HH:MM, 24-hour; start must be earlier than stop |
| `timezone` | `Africa/Lagos` | IANA time zone |

Run its tests with `terraform test`.
