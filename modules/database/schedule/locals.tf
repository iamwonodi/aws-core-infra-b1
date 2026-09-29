locals {
  start = split(":", var.start)
  stop  = split(":", var.stop)

  # Minutes since midnight, to compare the two times.
  start_minutes = tonumber(local.start[0]) * 60 + tonumber(local.start[1])
  stop_minutes  = tonumber(local.stop[0]) * 60 + tonumber(local.stop[1])

  start_expression = "cron(${tonumber(local.start[1])} ${tonumber(local.start[0])} ? * ${join(",", var.days)} *)"
  stop_expression  = "cron(${tonumber(local.stop[1])} ${tonumber(local.stop[0])} * * ? *)"

  # What to call for each kind of target, and the input naming it.
  targets = merge(
    { for engine, instance in var.instances : engine => { kind = "instance", id = instance.id, arn = instance.arn } },
    { for engine, cluster in var.clusters : engine => { kind = "cluster", id = cluster.id, arn = cluster.arn } },
  )

  api = {
    instance = { service = "rds", start = "startDBInstance", stop = "stopDBInstance", key = "DBInstanceIdentifier" }
    cluster  = { service = "docdb", start = "startDBCluster", stop = "stopDBCluster", key = "DBClusterIdentifier" }
  }

  schedules = merge(
    {
      for engine, target in local.targets : "${engine}-start" => {
        target     = "arn:aws:scheduler:::aws-sdk:${local.api[target.kind].service}:${local.api[target.kind].start}"
        input      = jsonencode({ (local.api[target.kind].key) = target.id })
        expression = local.start_expression
        purpose    = "Starts the ${engine} ${target.kind} on ${join(", ", var.days)} at ${var.start} ${var.timezone}."
      }
    },
    {
      for engine, target in local.targets : "${engine}-stop" => {
        target     = "arn:aws:scheduler:::aws-sdk:${local.api[target.kind].service}:${local.api[target.kind].stop}"
        input      = jsonencode({ (local.api[target.kind].key) = target.id })
        expression = local.stop_expression
        purpose    = "Stops the ${engine} ${target.kind} every day at ${var.stop} ${var.timezone}."
      }
    },
  )
}
