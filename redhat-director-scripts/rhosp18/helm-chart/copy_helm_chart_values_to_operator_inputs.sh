#!/bin/bash -x

set -e

# Define directories and files
CHART_DIR="tvo-chart"
VALUES_FILE="$CHART_DIR/values.yaml"
OVERRIDES_DIR="$CHART_DIR/values_overrides"
OPERATOR_INPUTS="tvo-operator-inputs.yaml"

# Temporary file for merged values
MERGED_VALUES=$(mktemp)

# Start with the base values.yaml
cp "$VALUES_FILE" "$MERGED_VALUES"

# Merge override files one by one
OVERRIDE_FILES=(
    "$OVERRIDES_DIR/trilio_inputs.yaml"
    "$OVERRIDES_DIR/trilio_inputs_dynamic.yaml"
    "$OVERRIDES_DIR/trilio_inputs_keystone.yaml"
)

for override in "${OVERRIDE_FILES[@]}"; do
    echo "Merging $override..."
    yq eval-all 'select(fi == 0) * select(fi == 1)' "$MERGED_VALUES" "$override" > "${MERGED_VALUES}.tmp"
    mv "${MERGED_VALUES}.tmp" "$MERGED_VALUES"
done

# Insert the merged values into tvo-operator-inputs.yaml under the spec.common section
echo "Inserting merged values into $OPERATOR_INPUTS..."
yq eval --inplace ".spec.common |= load(\"$MERGED_VALUES\")" "$OPERATOR_INPUTS"

# Cleanup temporary files
rm -f "$MERGED_VALUES"

echo "Merged values successfully into $OPERATOR_INPUTS"

