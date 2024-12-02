#!/bin/bash -x

set -e

# Define directories and files
CHART_DIR="tvo-chart"
VALUES_FILE="$CHART_DIR/values.yaml"
OVERRIDES_DIR="$CHART_DIR/values_overrides"
OPERATOR_INPUTS="tvo-operator-inputs.yaml"

# Temporary file for merged values
MERGED_VALUES=$(mktemp)

# Start with an empty YAML file for the merged values
cp "$VALUES_FILE" "$MERGED_VALUES"

# Merge override files one by one, including the base values.yaml
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

# Create a fresh tvo-operator-inputs.yaml file
cat <<EOF > "$OPERATOR_INPUTS"
apiVersion: tvo.trilio.io/v1
kind: TVOControlPlane
metadata:
  name: tvocontrolplane-v60
spec:
EOF

# Append the merged values into the .spec section of tvo-operator-inputs.yaml
yq eval ".spec |= load(\"$MERGED_VALUES\")" "$OPERATOR_INPUTS" > "${OPERATOR_INPUTS}.tmp"
mv "${OPERATOR_INPUTS}.tmp" "$OPERATOR_INPUTS"

# Cleanup temporary files
rm -f "$MERGED_VALUES"

echo "Merged values successfully into $OPERATOR_INPUTS"

