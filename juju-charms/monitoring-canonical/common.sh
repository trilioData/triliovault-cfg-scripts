#!/usr/bin/env bash
# Shared helpers sourced by the deploy.sh scripts in this directory.
# Requires: juju (with a working model context), jq.

# unit_ip <app-name>/<unit-number>  -> prints the unit's public address.
# Searches both top-level units and subordinate units nested under a
# principal unit's "subordinates" map (trilio-data-mover, trilio-horizon-plugin,
# and their mysql-router subordinates are all subordinate charms).
unit_ip() {
  local unit="$1"
  juju status --format=json | jq -r --arg u "$unit" '
    [ .applications[].units // {}
      | to_entries[]
      | ., (.value.subordinates // {} | to_entries[])
    ]
    | map(select(.key == $u))
    | .[0].value["public-address"] // empty
  '
}

# require_unit <app-name>/<unit-number> -> exits non-zero if the unit is not in `juju status`
require_unit() {
  local unit="$1"
  local ip
  ip=$(unit_ip "$unit")
  if [[ -z "${ip}" || "${ip}" == "null" ]]; then
    echo "ERROR: unit '${unit}' not found in 'juju status' — is it deployed in the current model?" >&2
    exit 1
  fi
  echo "${ip}"
}
