#!/bin/bash

# SPDX-FileCopyrightText: Copyright 2021 Amazon.com, Inc. or its affiliates.
# SPDX-License-Identifier: MIT-0

# If EKSCLUSTER_NAME exists use that value or set a default value
export EKSCLUSTER_NAME="${EKSCLUSTER_NAME:-aws-blog}"

echo "==============================================="
echo "  create IAM Role for Cloud9IDE ......"
echo "==============================================="
export C9_ROLE_NAME=${EKSCLUSTER_NAME}-C9Role
cat >/tmp/c9-trust-policy.json <<EOL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOL
aws iam create-role --role-name ${C9_ROLE_NAME} --assume-role-policy-document file:///tmp/c9-trust-policy.json
# add Administrator permissions to the role
aws iam attach-role-policy --role-name ${C9_ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
# Creating instace profile and associate to the role
aws iam create-instance-profile --instance-profile-name ${C9_ROLE_NAME}-instance-profile
aws iam add-role-to-instance-profile --role-name ${C9_ROLE_NAME} --instance-profile-name ${C9_ROLE_NAME}-instance-profile

echo "==============================================="
echo "  create Cloud9IDE and attach the role......"
echo "==============================================="

#Create Cloud9 Environment
C9_ENV_ID=`aws cloud9 create-environment-ec2 --name ${EKSCLUSTER_NAME}-ide --instance-type t3.medium --query "environmentId" --output text`

#Associate IAM role to Cloud9
aws ec2 associate-iam-instance-profile \
    --iam-instance-profile Name=${C9_ROLE_NAME}-instance-profile \
    --region ${AWS_REGION} \
    --instance-id $(aws ec2 describe-instances --region ${AWS_REGION} --filters Name=tag:aws:cloud9:environment,Values=${C9_ENV_ID} --query "Reservations[*].Instances[*].InstanceId" --output text
)

# Disable temporary credentials on Cloud9
aws cloud9 update-environment  --environment-id $C9_ENV_ID --managed-credentials-action DISABLE

echo "==============================================="
echo "  Use the URL to acces the Cloud9 IDE ......"
echo "==============================================="

echo "Navigate to this URL and continue the rest of the steps there: https://${AWS_REGION}.console.aws.amazon.com/cloud9/ide/${C9_ENV_ID}"