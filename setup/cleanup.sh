#!/bin/bash

# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0


export EKSCLUSTER_NAME="${EKSCLUSTER_NAME:-aws-blog}"
export EMRCLUSTER_NAME="${EKSCLUSTER_NAME}-emr"
export ACCOUNTID="$(aws sts get-caller-identity --query Account --output text)"
export AWS_REGION="$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')"
export S3BUCKET="${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}"
export ECR_URL="$ACCOUNTID.dkr.ecr.$AWS_REGION.amazonaws.com"

echo "Delete karpenter virtual EMR cluster"
export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '${EMRCLUSTER_NAME}-karpenter' && state == 'RUNNING'].id" --output text)

for Job_id in $(aws emr-containers list-job-runs --states RUNNING --virtual-cluster-id ${VIRTUAL_CLUSTER_ID} --query "jobRuns[?state=='RUNNING'].id" --output text ); do aws emr-containers cancel-job-run --id ${Job_id} --virtual-cluster-id ${VIRTUAL_CLUSTER_ID}; done
aws emr-containers delete-virtual-cluster --id ${VIRTUAL_CLUSTER_ID}

echo "Delete CAS virtual EMR cluster"
export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '${EMRCLUSTER_NAME}-ca' && state == 'RUNNING'].id" --output text)

for Job_id in $(aws emr-containers list-job-runs --states RUNNING --virtual-cluster-id ${VIRTUAL_CLUSTER_ID} --query "jobRuns[?state=='RUNNING'].id" --output text ); do aws emr-containers cancel-job-run --id ${Job_id} --virtual-cluster-id ${VIRTUAL_CLUSTER_ID}; done
aws emr-containers delete-virtual-cluster --id ${VIRTUAL_CLUSTER_ID}


echo "delete EMR on EKS IAM execution role "
export ROLE_NAME=${EMRCLUSTER_NAME}-execution-role
export POLICY_ARN=arn:aws:iam::$ACCOUNTID:policy/${ROLE_NAME}-policy
aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
aws iam delete-role --role-name $ROLE_NAME
aws iam delete-policy --policy-arn $POLICY_ARN


echo "Uninstall Karpenter"

kubectl delete -f setup/karpenter/provisioner.yml
helm uninstall karpenter --namespace karpenter
aws iam detach-role-policy --role-name="${EKSCLUSTER_NAME}-karpenter" --policy-arn="arn:aws:iam::${ACCOUNTID}:policy/KarpenterControllerPolicy-${EKSCLUSTER_NAME}"
aws iam delete-policy --policy-arn="arn:aws:iam::${ACCOUNTID}:policy/KarpenterControllerPolicy-${EKSCLUSTER_NAME}"
aws iam delete-role --role-name="${EKSCLUSTER_NAME}-karpenter"
aws cloudformation delete-stack --stack-name "Karpenter-${EKSCLUSTER_NAME}"
aws ec2 describe-launch-templates \
    | jq -r ".LaunchTemplates[].LaunchTemplateName" \
    | grep -i "Karpenter-${EKSCLUSTER_NAME}" \
    | xargs -I{} aws ec2 delete-launch-template --launch-template-name {}

echo "Uninstalling CAS"
helm uninstall cluster-autoscaler --namespace kube-system --wait

echo "Uninstall Node Termination handler"
helm uninstall aws-node-termination-handler --namespace kube-system --wait

echo "Uninstall Prometheus"
PID=$(aws amp list-workspaces --alias $EKSCLUSTER_NAME --query workspaces[].workspaceId --output text)
if ! [ -z "$PID" ]; then
	for id in $PID; do
		sleep 2
		echo "Delete $id"
		aws amp delete-workspace --workspace-id $id
	done
fi

helm uninstall prometheus --namespace prometheus --wait


echo "delete fluentbit for cloudwatch logs"

#Delete Fluent Bit daemonset
kubectl delete -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/fluent-bit/fluent-bit.yaml
# Delete configmap
kubectl delete configmap fluent-bit-cluster-info -n amazon-cloudwatch
#Delete amazon-cloudwatch namespace
kubectl delete -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml


echo "delete S3"
aws s3 rm s3://$S3BUCKET --recursive
aws s3api delete-bucket --bucket $S3BUCKET

echo "delete ECR image and repo"
aws ecr delete-repository \
    --repository-name eks-spark-benchmark \
    --force

echo "delete ALB if any"
vpcId=$(aws ec2 describe-vpcs --filters Name=tag:"karpenter.sh/discovery",Values=$EKSCLUSTER_NAME --query "Vpcs[*].VpcId" --output text)
ALB=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$vpcId'].LoadBalancerArn" --output text)
if ! [ -z "$ALB" ]; then
	for alb in $ALB; do
		sleep 2
		echo "Delete $alb"
		aws elbv2 delete-load-balancer --load-balancer-arn $alb
	done
fi
TG=$(aws elbv2 describe-target-groups --query "TargetGroups[?VpcId=='$vpcId'].TargetGroupArn" --output text)
if ! [ -z "$TG" ]; then
	for tg in $TG; do
		sleep 2
		echo "Delete Target groups $tg"
		aws elbv2 delete-target-group --target-group-arn $tg
	done
fi


echo "delete nodegroups"
eksctl delete nodegroup -f setup/eks-cluster/eksctl-config.yml --approve --wait
echo "delete EKS cluster"
eksctl delete cluster --name $EKSCLUSTER_NAME --wait

# delete cloud9
aws cloud9 delete-environment --environment-id $C9_PID