#!/bin/bash

# Get the directory where the script is located
script_dir=$(dirname "$0")

# Define input and output file paths
input_file="$script_dir/s3-cert.pem"
output_file="$script_dir/s3-cert-encoded.pem"

# Check if the input file exists
if [ ! -f "$input_file" ]; then
  echo "Input file $input_file does not exist."
  exit 1
fi

# Encode the certificate to base64 and write to the output file
base64 "$input_file" | sed 's/^/            /' > "$output_file"

# Notify the user of success
if [ $? -eq 0 ]; then
  echo "Certificate has been successfully encoded and saved to $output_file"
else
  echo "An error occurred during encoding."
  exit 1
fi
