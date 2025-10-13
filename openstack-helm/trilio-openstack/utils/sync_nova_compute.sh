#!/bin/bash
set -euo pipefail

# ==========================================
# Sync nova-compute-init.sh into Trilio templates
# Detect config files from init content
# ==========================================

NAMESPACE="openstack"
NOVA_CM="nova-bin"
DATAMOVER_MAIN="../templates/bin/_triliovault-datamover.sh.tpl"
DATAMOVER_INIT="../templates/bin/_triliovault-datamover-init.sh.tpl"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# ==========================================
# Fetch nova-compute-init.sh
# ==========================================
echo "Fetching nova-compute-init.sh from ConfigMap $NOVA_CM..."
nova_init=$(kubectl get cm -n "$NAMESPACE" "$NOVA_CM" -o jsonpath='{.data.nova-compute-init\.sh}' || true)
if [[ -z "$nova_init" ]]; then
  echo "ERROR: Could not fetch nova-compute-init.sh from ConfigMap $NOVA_CM."
  exit 1
fi

# ==========================================
# Inject nova-compute-init.sh content into init template
# ==========================================
echo "Injecting nova-compute-init.sh content into $DATAMOVER_INIT..."
tmp_out=$(mktemp)
trap 'rm -f "$tmp_out"' EXIT

# Keep lines from 'migration_interface' onward only
nova_init_clean=$(echo "$nova_init" | sed -n '/migration_interface/,$p')

while IFS= read -r line; do
  if [[ "$line" == *"<INJECT_INIT_FILES>"* ]]; then
    indent_prefix="${line%%<INJECT_INIT_FILES>*}"
    while IFS= read -r init_line; do
      echo "${indent_prefix}${init_line}" >> "$tmp_out"
    done < <(echo "$nova_init_clean")
  else
    echo "$line" >> "$tmp_out"
  fi
done < "$DATAMOVER_INIT"

mv "$tmp_out" "$DATAMOVER_INIT"

sed -i 's|/tmp/pod-shared/|/tmp/pod-shared-triliovault-datamover/|g' "$DATAMOVER_INIT"
sed -i 's|${NOVA_USER_UID}|nova|g' "$DATAMOVER_INIT"

echo "Updated $DATAMOVER_INIT"

# ==========================================
# Parse injected init file to detect config files
# ==========================================
echo "Parsing config files from $DATAMOVER_INIT..."
declare -A seen
config_lines=()

while read -r line; do
  if [[ "$line" =~ [\>\ ]([/a-zA-Z0-9._-]+\.conf) ]]; then
    file_path="${BASH_REMATCH[1]}"
    base_name="$(basename "$file_path")"
    if [[ "$file_path" == ".Values.conf" ]]; then
      continue
    fi
    if [[ -z "${seen[$file_path]:-}" ]]; then
      seen[$file_path]=1
      config_lines+=("CMD+=\" --config-file=${file_path}\"")
    fi
  fi
done < "$DATAMOVER_INIT"

if [[ ${#config_lines[@]} -eq 0 ]]; then
  echo "No config files detected from init script."
else
  echo "Found config files:"
  printf ' - %s\n' "${config_lines[@]}"
fi

# ==========================================
# Inject config files into _triliovault-datamover.sh.tpl
# ==========================================
echo "Injecting config files into $DATAMOVER_MAIN..."
tmp_out=$(mktemp)
trap 'rm -f "$tmp_out"' EXIT

while IFS= read -r line; do
  if [[ "$line" == *"<INJECT_CONFIG_FILES>"* ]]; then
    indent_prefix="${line%%<INJECT_CONFIG_FILES>*}"
    for l in "${config_lines[@]}"; do
      echo "${indent_prefix}${l}" >> "$tmp_out"
    done
  else
    echo "$line" >> "$tmp_out"
  fi
done < "$DATAMOVER_MAIN"

mv "$tmp_out" "$DATAMOVER_MAIN"
echo "Updated $DATAMOVER_MAIN"
