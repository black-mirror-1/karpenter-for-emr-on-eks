#!/bin/bash

# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0

echo "==============================================="
echo "  install CLI tools ......"
echo "==============================================="

export KUBECTL_URL="${KUBECTL_URL:-https://s3.us-west-2.amazonaws.com/amazon-eks/1.22.6/2022-03-09/bin/linux/amd64/kubectl}"
export HELM_VERSION="${HELM_VERSION:-v3.9.0}"

# Install envsubst (from GNU gettext utilities) and bash-completion
sudo yum -y install jq gettext bash-completion moreutils

# Update aws cli
echo current aws cli version is $(aws --version), updating...

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
echo updated aws cli version is $(aws --version)

# Install eksctl
curl -s --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv -v /tmp/eksctl /usr/local/bin
echo eksctl version is $(eksctl version)


# Install kubectl
curl -s -o kubectl ${KUBECTL_URL}
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
#(optional) add alias for kubectl
echo "alias k=kubectl" | tee -a ~/.bash_profile
source ~/.bash_profile
echo kubectl version is $(kubectl version --short --client)

# Install helm on cloudshell
curl -s https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar xz -C ./ &&
    sudo mv linux-amd64/helm /usr/local/bin/helm &&
    rm -r linux-amd64
echo helm cli version is $(helm version --short)