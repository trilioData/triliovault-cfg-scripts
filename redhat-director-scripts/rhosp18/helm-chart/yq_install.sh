#!/bin/bash  -x

set -e 
#pip3 install yq

#!/bin/bash

set -e

# Define the version to install
VERSION="4.33.3"

# Download the yq binary
echo "Downloading yq version $VERSION..."
curl -L "https://github.com/mikefarah/yq/releases/download/v${VERSION}/yq_linux_amd64" -o /usr/local/bin/yq

# Make it executable
echo "Setting executable permissions..."
chmod +x /usr/local/bin/yq

# Verify installation
echo "Verifying yq installation..."
yq --version

echo "yq version $VERSION installed successfully!"

