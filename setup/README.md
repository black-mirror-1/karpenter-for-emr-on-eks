# Infrastructure Setup

## Setup cloud9 IDE


Run the following scripts in [AWS CloudShell](https://us-east-1.console.aws.amazon.com/cloudshell?region=us-east-1). The default region is `us-east-1`. **Change it on your console if needed**.

```bash
# clone the repo
git clone https://github.com/black-mirror-1/karpenter-for-emr-on-eks.git
cd karpenter-for-emr-on-eks.git
````

Run this script to create Cloud9 IDE and assign an admin role to it
```bash
./setup/create-cloud9-ide.sh
```

Navigate to the Cloud9 IDE using the URL from the output of the script.

NOTE: All the steps from now on are run within Clou9 IDE

## Install tools on cloud9 IDE

Setup the env variables required before installing the tools

```bash
# Install envsubst (from GNU gettext utilities) and bash-completion
sudo yum -y install jq gettext bash-completion moreutils

# Setup env variables required
export EKSCLUSTER_NAME=aws-blog
export EMRCLUSTER_NAME=${EKSCLUSTER_NAME}-emr
export ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
export S3BUCKET=${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}
export EKS_VERSION="1.22"
# get the link to the same version as EKS from here https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html
export KUBECTL_URL="https://s3.us-west-2.amazonaws.com/amazon-eks/1.22.6/2022-03-09/bin/linux/amd64/kubectl"
export HELM_VERSION="v3.9.0"
export KARPENTER_VERSION="v0.11.1"
# get the most recent matching version of the Cluster Autoscaler from here https://github.com/kubernetes/autoscaler/releases
export CAS_VERSION="v1.22.3"
```


Clone the git repository

```bash
cd ~/environment
git clone https://github.com/black-mirror-1/karpenter-for-emr-on-eks.git
cd ~/environment/karpenter-for-emr-on-eks
```

Install cloud9 cli tools

```bash
cd ~/environment/karpenter-for-emr-on-eks
./setup/c9-install-tools.sh
```

Create EMR on EKS and Karpenter infrastructure

```bash
cd ~/environment/karpenter-for-emr-on-eks
./setup/create-eks-emr-infra.sh
```


