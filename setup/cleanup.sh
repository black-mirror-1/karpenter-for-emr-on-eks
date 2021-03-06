#!/bin/bash

# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0

export EMRCLUSTER_NAME=emr-on-$EKSCLUSTER_NAME
export ACCOUNTID=$(aws sts get-caller-identity --query Account --output text)
export S3BUCKET=${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}

export EKSCLUSTER_NAME="${EKSCLUSTER_NAME:-aws-blog}"
export EMRCLUSTER_NAME="${EMRCLUSTER_NAME:-${EKSCLUSTER_NAME}-emr}"
export ACCOUNTID="${ACCOUNTID:-$(aws sts get-caller-identity --query Account --output text)}"
export AWS_REGION="{$AWS_REGION:-$(curl -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')}"
export S3BUCKET="${S3BUCKET:-${EMRCLUSTER_NAME}-${ACCOUNTID}-${AWS_REGION}}"
export EKS_VERSION="${EKS_VERSION:-1.22}"
# get the link to the same version as EKS from here https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html
export KUBECTL_URL="${KUBECTL_URL:-https://s3.us-west-2.amazonaws.com/amazon-eks/1.22.6/2022-03-09/bin/linux/amd64/kubectl}"
export HELM_VERSION="${HELM_VERSION:-v3.9.0}"
export KARPENTER_VERSION="${KARPENTER_VERSION:-v0.11.1}"
# get the most recent matching version of the Cluster Autoscaler from here https://github.com/kubernetes/autoscaler/releases
export CAS_VERSION="${CAS_VERSION:-v1.22.3}"

echo "delete EMR on EKS IAM execution role "
export ROLE_NAME=${EMRCLUSTER_NAME}-execution-role
export POLICY_ARN=arn:aws:iam::$ACCOUNTID:policy/${ROLE_NAME}-policy
aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
aws iam delete-role --role-name $ROLE_NAME
aws iam delete-policy --policy-arn $POLICY_ARN
echo "delete Karpenter role"
export K_ROLE_NAME=${EKSCLUSTER_NAME}-karpenter
export K_POLICY_ARN=arn:aws:iam::$ACCOUNTID:policy/KarpenterControllerPolicy-${EKSCLUSTER_NAME}
aws iam detach-role-policy --role-name $K_ROLE_NAME --policy-arn $K_POLICY_ARN
aws iam delete-role --role-name $K_ROLE_NAME
aws iam delete-policy --policy-arn $K_POLICY_ARN

echo "delete S3"
aws s3 rm s3://$S3BUCKET --recursive
aws s3api delete-bucket --bucket $S3BUCKET

echo "delete Grafana workspace"
WID=$(aws grafana list-workspaces --query "workspaces[?name=='$EMRCLUSTER_NAME'].id" --output text)
if ! [ -z "$WID" ]; then
	for id in $WID; do
		sleep 2
		echo "Delete $id"
		aws grafana delete-workspace --workspace-id $id
	done
fi
echo "delete Prometheus worksapce"
PID=$(aws amp list-workspaces --alias $EKSCLUSTER_NAME --query workspaces[].workspaceId --output text)
if ! [ -z "$PID" ]; then
	for id in $PID; do
		sleep 2
		echo "Delete $id"
		aws amp delete-workspace --workspace-id $id
	done
fi

echo "delete ALB"
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
# delete cloud9
env_ls=$(aws cloud9 list-environments --query environmentIds --output text)
if ! [ -z "$env_ls" ]; then
	for l in $env_ls; do
		ts=$(aws cloud9 describe-environments --environment-ids $l --query "environments[?name=='workshop-env']")
		if ! [ -z "$ts" ]; then
			aws cloud9 delete-environment --environment-id $l
		fi
	done
fi
echo "delete karpenter"
aws cloudformation delete-stack --stack-name Karpenter-$EKSCLUSTER_NAME
echo "delete EKS cluster"
eksctl delete cluster --name $EKSCLUSTER_NAME
echo "delete EMR virtual cluster"
export VIRTUAL_CLUSTER_ID=$(aws emr-containers list-virtual-clusters --query "virtualClusters[?name == '${EMRCLUSTER_NAME}' && state == 'RUNNING'].id" --output text)
aws emr-containers delete-virtual-cluster --id $VIRTUAL_CLUSTER_ID