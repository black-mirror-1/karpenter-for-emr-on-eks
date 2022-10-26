#!/bin/bash

# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0

# If env variables exists use that value or set a default value

export EKSCLUSTER_NAME="${EKSCLUSTER_NAME:-aws-blog}"
export EMRCLUSTER_NAME="${EMRCLUSTER_NAME:-${EKSCLUSTER_NAME}-emr}"
export ACCOUNTID="${ACCOUNTID:-$(aws sts get-caller-identity --query Account --output text)}"
export AWS_REGION="${AWS_REGION:-$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')}"
export S3BUCKET="${S3BUCKET:-${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}}"
export EKS_VERSION="${EKS_VERSION:-1.23}"
# get the link to the same version as EKS from here https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html
export KUBECTL_URL="${KUBECTL_URL:-https://s3.us-west-2.amazonaws.com/amazon-eks/1.23.7/2022-06-29/bin/darwin/amd64/kubectl}"
export HELM_VERSION="${HELM_VERSION:-v3.9.4}"
export KARPENTER_VERSION="${KARPENTER_VERSION:-v0.18.1}"
# get the most recent matching version of the Cluster Autoscaler from here https://github.com/kubernetes/autoscaler/releases
export CAS_VERSION="${CAS_VERSION:-v1.23.1}"

cd ~/environment/karpenter-for-emr-on-eks
# create S3 bucket for application
aws s3 mb s3://$S3BUCKET --region $AWS_REGION
#copy pod templates
aws s3 sync sample-workloads/pod-template s3://$S3BUCKET/pod-template

echo "==============================================="
echo "  setup IAM roles for EMR on EKS ......"
echo "==============================================="
# Create a job execution role
export ROLE_NAME=${EMRCLUSTER_NAME}-execution-role
cat >/tmp/trust-policy.json <<EOL
{
  "Version": "2012-10-17",
  "Statement": [ {
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    } ]
}
EOL
sed -i -- 's/{S3BUCKET}/'$S3BUCKET'/g' sample-workloads/iam/job-execution-policy.json
aws iam create-policy --policy-name $ROLE_NAME-policy --policy-document file://sample-workloads/iam/job-execution-policy.json
aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file:///tmp/trust-policy.json
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::$ACCOUNTID:policy/$ROLE_NAME-policy

echo "==============================================="
echo "  Create EKS Cluster ......"
echo "==============================================="
sed -i -- 's/{AWS_REGION}/'$AWS_REGION'/g' setup/eks-cluster/eksctl-config.yml
sed -i -- 's/{EKSCLUSTER_NAME}/'$EKSCLUSTER_NAME'/g' setup/eks-cluster/eksctl-config.yml
sed -i -- 's/{EKS_VERSION}/'$EKS_VERSION'/g' setup/eks-cluster/eksctl-config.yml
sed -i -- 's/{ACCOUNTID}/'$ACCOUNTID'/g' setup/eks-cluster/eksctl-config.yml

eksctl create cluster -f setup/eks-cluster/eksctl-config.yml
aws eks update-kubeconfig --name $EKSCLUSTER_NAME --region $AWS_REGION

echo "==============================================="
echo "  Install Node termination Handler for Spot....."
echo "==============================================="
helm repo add eks https://aws.github.io/eks-charts
helm install aws-node-termination-handler \
             --namespace kube-system \
             --version 0.18.3 \
             --set nodeSelector."karpenter\\.sh/capacity-type"=spot \
             eks/aws-node-termination-handler


echo "==============================================="
echo "  Install Cluster Autoscaler (CA) to EKS ......"
echo "==============================================="
sed -i -- 's/{AWS_REGION}/'$AWS_REGION'/g' setup/helm/cluster-autoscaler-values.yml
sed -i -- 's/{EKSCLUSTER_NAME}/'$EKSCLUSTER_NAME'/g' setup/helm/cluster-autoscaler-values.yml
sed -i -- 's/{CAS_VERSION}/'$CAS_VERSION'/g' setup/helm/cluster-autoscaler-values.yml
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler -n kube-system -f setup/helm/cluster-autoscaler-values.yml

echo "==============================================="
echo "  Install Karpenter to EKS ......"
echo "==============================================="
# kubectl create namespace karpenter
# create IAM role and launch template
CONTROLPLANE_SG=$(aws eks describe-cluster --name $EKSCLUSTER_NAME --region $AWS_REGION --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
DNS_IP=$(kubectl get svc -n kube-system | grep kube-dns | awk '{print $3}')
API_SERVER=$(aws eks describe-cluster --region ${AWS_REGION} --name ${EKSCLUSTER_NAME} --query 'cluster.endpoint' --output text)
B64_CA=$(aws eks describe-cluster --region ${AWS_REGION} --name ${EKSCLUSTER_NAME} --query 'cluster.certificateAuthority.data' --output text)

sed -i -- 's/{EKS_VERSION}/'$EKS_VERSION'/g' setup/karpenter/karpenter-setup-cfn.yml
aws cloudformation deploy \
    --stack-name Karpenter-${EKSCLUSTER_NAME} \
    --template-file setup/karpenter/karpenter-setup-cfn.yml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=$EKSCLUSTER_NAME" "EKSClusterSgId=$CONTROLPLANE_SG" "APIServerURL=$API_SERVER" "B64ClusterCA=$B64_CA" "EKSDNS=$DNS_IP"

eksctl create iamidentitymapping \
    --username system:node:{{EC2PrivateDNSName}} \
    --cluster "${EKSCLUSTER_NAME}" \
    --arn "arn:aws:iam::${ACCOUNTID}:role/KarpenterNodeRole-${EKSCLUSTER_NAME}" \
    --group system:bootstrappers \
    --group system:nodes

# controller role
eksctl create iamserviceaccount \
    --cluster "${EKSCLUSTER_NAME}" --name karpenter --namespace karpenter \
    --role-name "${EKSCLUSTER_NAME}-karpenter" \
    --attach-policy-arn "arn:aws:iam::${ACCOUNTID}:policy/KarpenterControllerPolicy-${EKSCLUSTER_NAME}" \
    --approve

# aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
export KARPENTER_IAM_ROLE_ARN="arn:aws:iam::${ACCOUNTID}:role/${EKSCLUSTER_NAME}-karpenter"
# Install Karpenter helm chart
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version ${KARPENTER_VERSION} --namespace karpenter --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set clusterName=${EKSCLUSTER_NAME} \
  --set clusterEndpoint=${API_SERVER} \
  --set aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${EKSCLUSTER_NAME} \
  --wait # for the defaulting webhook to install before creating a Provisioner

# helm repo add karpenter https://charts.karpenter.sh
# helm repo update
# helm upgrade --install karpenter karpenter/karpenter --namespace karpenter --version ${KARPENTER_VERSION} \
#     --set serviceAccount.create=false --set serviceAccount.name=karpenter --set nodeSelector.app=ops \
#     --set clusterName=${EKSCLUSTER_NAME} --set clusterEndpoint=${API_SERVER} --wait # for the defaulting webhook to install before creating a Provisioner

#turn on debug mode
kubectl patch configmap config-logging -n karpenter --patch '{"data":{"loglevel.controller":"debug"}}'

sed -i -- 's/{AWS_REGION}/'$AWS_REGION'/g' setup/karpenter/provisioner.yml
sed -i -- 's/{EKSCLUSTER_NAME}/'$EKSCLUSTER_NAME'/g' setup/karpenter/provisioner.yml
kubectl apply -f setup/karpenter/provisioner.yml


echo "====================================================="
echo "  Install Prometheus to EKS for monitroing ......"
echo "====================================================="
kubectl create namespace prometheus

amp=$(aws amp list-workspaces --query "workspaces[?alias=='$EKSCLUSTER_NAME'].workspaceId" --output text)
if [ -z "$amp" ]; then
    echo "Creating a new prometheus workspace..."
    export WORKSPACE_ID=$(aws amp create-workspace --alias $EKSCLUSTER_NAME --query workspaceId --output text)
else
    echo "A prometheus workspace already exists"
    export WORKSPACE_ID=$amp
fi
export INGEST_ROLE_ARN="arn:aws:iam::${ACCOUNTID}:role/${EKSCLUSTER_NAME}-prometheus-ingest"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kube-state-metrics https://kubernetes.github.io/kube-state-metrics
helm repo update
sed -i -- 's/{AWS_REGION}/'$AWS_REGION'/g' setup/helm/prometheus-values.yml
sed -i -- 's/{ACCOUNTID}/'$ACCOUNTID'/g' setup/helm/prometheus-values.yml
sed -i -- 's/{WORKSPACE_ID}/'$WORKSPACE_ID'/g' setup/helm/prometheus-values.yml
sed -i -- 's/{EKSCLUSTER_NAME}/'$EKSCLUSTER_NAME'/g' setup/helm/prometheus-values.yml
helm upgrade --install prometheus prometheus-community/prometheus -n prometheus -f setup/helm/prometheus-values.yml

# Install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml


echo "==============================================="
echo "  Install fluentbit for cloudwatch logs......"
echo "==============================================="

# Create amazon-cloudwatch namespace
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml

#create ConfigMap named fluent-bit-cluster-info
ClusterName=$EKSCLUSTER_NAME
RegionName=$AWS_REGION
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
kubectl create configmap fluent-bit-cluster-info \
--from-literal=cluster.name=${ClusterName} \
--from-literal=http.server=${FluentBitHttpServer} \
--from-literal=http.port=${FluentBitHttpPort} \
--from-literal=read.head=${FluentBitReadFromHead} \
--from-literal=read.tail=${FluentBitReadFromTail} \
--from-literal=logs.region=${RegionName} -n amazon-cloudwatch


#Deploy Fluent Bit as daemonset
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/fluent-bit/fluent-bit.yaml


echo "==============================================="
echo "  Enable EMR on EKS ......"
echo "==============================================="
kubectl create namespace emr-ca
eksctl create iamidentitymapping --cluster $EKSCLUSTER_NAME --namespace emr-ca --service-name "emr-containers"
aws emr-containers update-role-trust-policy --cluster-name $EKSCLUSTER_NAME --namespace emr-ca --role-name $ROLE_NAME

# Create emr virtual cluster
aws emr-containers create-virtual-cluster --name $EMRCLUSTER_NAME-ca \
    --container-provider '{
        "id": "'$EKSCLUSTER_NAME'",
        "type": "EKS",
        "info": { "eksInfo": { "namespace":"'emr-ca'" } }
    }'

kubectl create namespace emr-karpenter
eksctl create iamidentitymapping --cluster $EKSCLUSTER_NAME --namespace emr-karpenter --service-name "emr-containers"
aws emr-containers update-role-trust-policy --cluster-name $EKSCLUSTER_NAME --namespace emr-karpenter --role-name $ROLE_NAME

# Create emr virtual cluster
aws emr-containers create-virtual-cluster --name $EMRCLUSTER_NAME-karpenter \
    --container-provider '{
        "id": "'$EKSCLUSTER_NAME'",
        "type": "EKS",
        "info": { "eksInfo": { "namespace":"'emr-karpenter'" } }
    }'