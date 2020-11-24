#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# About create_studio.sh
# Creates a new Amazon EMR Studio and its associated AWS resource stack
# through the following actions:
#    - Prompts for AWS Region.
#    - Checks that AWS SSO is enabled in the specified Region.
#    - Prompts for the new EMR Studio name.
#    - Provisions a Studio resource stack called emr-studio-dependencies
#      using the full_studio_dependencies.yml AWS CloudFormation template 
#      located in the same repository.
#    - Creates an EMR Studio using the provisioned resources.
#    - Returns the details about the new Studio.
#    
# Prerequisites
#    - The default Amazon EMR IAM roles, security groups,
#      and Amazon S3 logging bucket must already exist in the AWS Region 
#      where you want to create the Studio.
#    - You must have the jq command-line JSON processer installed 
#      (https://stedolan.github.io/jq/download). The script uses jq to
#      parse and display AWS CLI return values.


# Read AWS Region
echo "Enter the code for the AWS Region in which you want to create the Studio. For example, us-east-1."
read region

# Verify that the user has enabled AWS SSO in the specified AWS Region
aws sso-admin list-instances --region $region > /dev/null
retVal=$?
if [ $retVal -ne 0 ]; then
    echo "SSO is not enabled in the specified Region: $region. Enable SSO in $region and try again."
    exit $retVal
fi

# Read Studio name
echo "Enter a descriptive name for the Studio. For example, My first EMR Studio."
read studio_name

# Retrieve full_studio_dependencies.yml
curl https://raw.githubusercontent.com/aws-samples/emr-studio-samples/main/full_studio_dependencies.yml --output full_studio_dependencies.yml

# Provision the Studio resource stack using AWS CloudFormation
stack_name=emr-studio-dependencies
echo "Creating the following CloudFormation stack to provision dependencies for the Studio: $stack_name. This takes a few minutes..."
aws cloudformation --region $region \
create-stack --stack-name $stack_name \
--template-body 'file://full_studio_dependencies.yml' \
--capabilities CAPABILITY_NAMED_IAM

# Check whether the resource stack has been created
status=""
while [ "$status" != "CREATE_COMPLETE" ]
do
  status=$(aws cloudformation --region $region describe-stacks --stack-name $stack_name --query "Stacks[0].StackStatus" --output text)
  if [[ "$status" == "CREATE_COMPLETE" ]]
  then
    break
  elif [[ "$status" != "CREATE_IN_PROGRESS" ]]
  then
    echo "Failed to create the Cloudformation stack. Fix the cause, delete the failed stack ($stack_name), and try again."
    exit 1
  else
    echo "Waiting for CloudFormation to finish. Current status: $status"
    echo "Checking the status again in 10 seconds..."
    sleep 10
  fi
done

# Return the resource stack details
outputs=$(aws cloudformation --region $region describe-stacks --stack-name $stack_name --query "Stacks[0].Outputs" --output json)

# Update the engine security group to remove all outbound traffic rules
engine_sg=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EngineSecurityGroup") | .OutputValue')
aws ec2 --region $region revoke-security-group-egress --group-id "$engine_sg" --protocol all --port all --cidr 0.0.0.0/0

# Create the Studio
echo "Creating a new EMR Studio with the following dependencies:"
echo "------------------------------------------------------------"
echo $outputs | jq -r '.[] | "\(.OutputKey)\t\(.OutputValue)"'
echo "------------------------------------------------------------"

vpc=$(echo $outputs | jq -r '.[] | select(.OutputKey=="VPC") | .OutputValue')
private_subnet_1=$(echo $outputs | jq -r '.[] | select(.OutputKey=="PrivateSubnet1") | .OutputValue')
private_subnet_2=$(echo $outputs | jq -r '.[] | select(.OutputKey=="PrivateSubnet2") | .OutputValue')
service_role=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EMRStudioServiceRoleArn") | .OutputValue')
user_role=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EMRStudioUserRoleArn") | .OutputValue')
workspace_sg=$(echo $outputs | jq -r '.[] | select(.OutputKey=="WorkspaceSecurityGroup") | .OutputValue')
storage_bucket=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EmrStudioStorageBucket") | .OutputValue')

echo "......"

# Return details about the new Studio
studio_outputs=$(aws emr create-studio --region $region \
--name $studio_name \
--auth-mode SSO \
--vpc-id $vpc \
--subnet-ids $private_subnet_1 $private_subnet_2 \
--service-role $service_role \
--user-role $user_role \
--workspace-security-group-id $workspace_sg \
--engine-security-group-id $engine_sg \
--default-s3-location s3://$storage_bucket --output json)


studio_id=$(echo $studio_outputs | jq -r '.["StudioId"]')
studio_url=$(echo $studio_outputs | jq -r '.["Url"]')

# Return additional information about managing the Studio
echo "Successfully created an EMR Studio with this ID: $studio_id"
echo "Users can log in to the Studio with this access URL: $studio_url"
printf "\n"

echo "To fetch details about the Studio, use:"
printf "aws emr describe-studio --region $region --studio-id $studio_id"
printf "\n"

echo "To list all of the Studios in the specified Region, use:"
printf "aws emr list-studios --region $region"

printf "\n"
echo "To delete the Studio, use:"
echo "aws emr delete-studio --region $region --studio-id $studio_id"
printf "\n"

echo "Specify one of the following session policies when you assign a user or group to the Studio: "
basic_policy=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EMRStudioBasicUserPolicyArn") | .OutputValue')
intermediate_policy=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EMRStudioIntermediateUserPolicyArn") | .OutputValue')
advanced_policy=$(echo $outputs | jq -r '.[] | select(.OutputKey=="EMRStudioAdvancedUserPolicyArn") | .OutputValue')
echo "------------------------------------------------------------"
echo $basic_policy
echo $intermediate_policy
echo $advanced_policy ;
echo "------------------------------------------------------------"

printf "\n"
echo "To assign a user (for example, hello@world) to the Studio and attach a session policy, use:"
echo "aws emr create-studio-session-mapping --region $region --studio-id $studio_id --identity-name hello@world --identity-type USER --session-policy-arn $advanced_policy"

printf "\n"
echo "To assign a group (for example, data-org) to the Studio and attach a session policy, use:"
echo "aws emr create-studio-session-mapping --region $region --studio-id $studio_id --identity-name data-org --identity-type GROUP --session-policy-arn $advanced_policy"
