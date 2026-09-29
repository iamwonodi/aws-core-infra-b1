locals {
  # Every person's database login, platform.<name>: this list reaches every
  # service's database. A service's own user never contains a dot, and a
  # service's agents are <service>.<name>, so the three cannot collide.
  usernames = { for name, person in var.people : name => "platform.${name}" }

  writers = [for name, person in var.people : name if person.access == "write"]
}
