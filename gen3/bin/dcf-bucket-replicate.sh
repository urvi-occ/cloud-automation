#!/bin/bash

source "${GEN3_HOME}/gen3/lib/utils.sh"
gen3_load "gen3/gen3setup"

if ! hostname="$(g3kubectl get configmap manifest-global -o json | jq -r .data.hostname)"; then
    gen3_log_err "could not determine hostname from manifest-global - bailing out"
    return 1
fi

jobId=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4 ; echo '')

prefix="${hostname//./-}-dcf-bucket-replicate-${jobId}"
saName=$(echo "${prefix}-sa")


# function to create a job and return a job id
#
# @param source_bucket: the bucket where objects will be copied from
# @param manifest: a manifest (tsv) of files to replicate. Required colums: project_id, url
# @param mapping: a json file that maps project_id to target bucket
#
gen3_dcf_create_aws_batch() {
  echo "dcf create"
  if [[ $# -lt 3 ]]; then
    gen3_log_info "Invalid format, should be: gen3 dcf-bucket-replicate --bucket BUCKET --manifest MANIFEST --mapping MAPPING"
    exit 1
  fi
  source_bucket=$1
  manifest=$2
  mapping=$3
  echo $prefix

  local job_queue=$(echo "${prefix}_queue_job")
  local job_definition=$(echo "${prefix}-batch_job_definition")
  local temp_bucket=$(echo "${prefix}-temp-bucket")

  # Get aws credetial of fence_bot iam user
  local access_key=$(gen3 secrets decode fence-config fence-config.yaml | yq -r .AWS_CREDENTIALS.fence_bot.aws_access_key_id)
  local secret_key=$(gen3 secrets decode fence-config fence-config.yaml | yq -r .AWS_CREDENTIALS.fence_bot.aws_secret_access_key)

  if [ "$secret_key" = "null" ]; then
    gen3_log_err "No fence_bot aws credential block in fence_config.yaml"
    return 1
  fi

  gen3 workon default ${prefix}__batch
  gen3 cd

  local accountId=$(gen3_aws_run aws sts get-caller-identity | jq -r .Account)

  mkdir -p $(gen3_secrets_folder)/g3auto/dcfbucketreplicate/
  credsFile="$(gen3_secrets_folder)/g3auto/dcfbucketreplicate/creds.json"
  cat - > "$credsFile" <<EOM
{
  "region": "us-east-1",
  "aws_access_key_id": "$access_key",
  "aws_secret_access_key": "$secret_key"
}
EOM
  gen3 secrets sync "initialize dcfbucketreplicate/creds.json"

  cat << EOF > ${prefix}-job-definition.json
{
    "image": "quay.io/cdis/object_copy:master",
    "memory": 256,
    "vcpus": 1,
    "environment": [
        {"name": "ACCESS_KEY_ID", "value": "${access_key}"},
        {"name": "SECRET_ACCESS_KEY", "value": "${secret_key}"},
        {"name": "SOURCE_BUCKET", "value": "${source_bucket}"},
        {"name": "DESTINTION_BUCKET", "value": "${destination_bucket}"}
    ]
}

EOF
  cat << EOF > config.tfvars
container_properties         = "./${prefix}-job-definition.json"
iam_instance_role            = "${prefix}-iam_ins_role"
iam_instance_profile_role    = "${prefix}-iam_ins_profile_role"
aws_batch_service_role       = "${prefix}_role"
aws_batch_compute_environment_sg = "${prefix}-compute_env_sg"
role_description             = "${prefix}-role to run aws batch"
batch_job_definition_name    = "${prefix}-batch_job_definition"
compute_environment_name     = "${prefix}-compute-env"
batch_job_queue_name         = "${job_queue}"
sqs_queue_name               = "${prefix}-batch-job-queue"
output_bucket_name           = "${temp_bucket}"
EOF

  cat << EOF > sa.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
             "Effect": "Allow",
             "Action": "batch:*",
             "Resource": "arn:aws:batch:us-east-1:${accountId}:job-definition/${job_definition}"
        },
        {
             "Effect": "Allow",
             "Action": "batch:*",
             "Resource":"arn:aws:batch:us-east-1:${accountId}:job-queue/${job_queue}"
        },
        {
             "Effect": "Allow",
             "Action": "s3:*",
             "Resource":[
               "arn:aws:s3:::${source_bucket}",
               "arn:aws:s3:::${destination_bucket}",
               "arn:aws:s3:::${destination_bucket}/*",
               "arn:aws:s3:::${source_bucket}/*"
             ]
        }
    ]
}
EOF

  gen3 tfplan 2>&1
  gen3 tfapply 2>&1
  if [[ $? != 0 ]]; then
    gen3_log_err "Unexpected error running gen3 tfapply."
    return 1
  fi
  sleep 30

  # Create a service account for k8s job for submitting jobs

  gen3 iam-serviceaccount -c $saName -p sa.json

  # Run k8s jobs to submitting jobs
  gen3 gitops filter $HOME/cloud-automation/kube/services/jobs/dcf-bucket-replication-job.yaml SOURCE_BUCKET $source_bucket MANIFEST $manifest MAPPING $mapping JOB_QUEUE $job_queue JOB_DEFINITION $job_definition | sed "s|sa-#SA_NAME_PLACEHOLDER#|$saName|g" | sed "s|dcf-bucket-replication#PLACEHOLDER#|dcf-bucket-replication-${jobId}|g" | tee $HOME/cloud-automation/kube/services/jobs/dcf-bucket-replication-${jobId}-job.yaml
  gen3 job run dcf-bucket-replication-${jobId}
  gen3_log_info "The job is started. Job ID: ${jobId}"

}

# function to check job status
#
# @param job-id
#
gen3_dcf_replicate_generating_status() {
  gen3_log_info "Please use kubectl logs -f dcf-bucket-replicate-{jobid}-xxx command"
}


# Show help
gen3_dcf_bucket_replicate_help() {
  gen3 help dcf-bucket-replicate
}

# function to list all jobs
gen3_dcf_bucket_replicate_list() {
  local search_dir="$HOME/.local/share/gen3/default"
  for entry in `ls $search_dir`; do
    if [[ $entry == *"__batch" ]]; then
      # jobid=$(echo $entry | sed -n "s/^.*-\(\S*\)__batch$/\1/p")
      # echo $jobid
      jobid=$(echo $entry | sed -n "s/${hostname//./-}-bucket-manifest-\(\S*\)__batch$/\1/p")
      if [[ $jobid != "" ]]; then
        echo $jobid
      fi
    fi
  done
}

# tear down the infrastructure
gen3_dcf_batch_cleanup() {
  if [[ $# -lt 1 ]]; then
    gen3_log_info "Need to provide a job-id "
    exit 1
  fi
  jobId=$1

  local search_dir="$HOME/.local/share/gen3/default"
  local is_jobid=0
  for entry in `ls $search_dir`; do
    if [[ $entry == *"__batch" ]]; then
      item=$(echo $entry | sed -n "s/^.*-\(\S*\)__batch$/\1/p")
      if [[ "$item" == "$jobId" ]]; then
        is_jobid=1
      fi
    fi
  done
  if [[ "$is_jobid" == 0 ]]; then
    gen3_log_err "job id does not exist"
    exit 1
  fi

  local prefix="${hostname//./-}-dcf-bucket-replicate-${jobId}"
  local saName=$(echo "${prefix}-sa" | head -c63)

  gen3 workon default ${prefix}__batch
  gen3 cd
  gen3_load "gen3/lib/terraform"
  gen3_terraform destroy
  gen3 trash --apply

  # Delete service acccount, role and policy attached to it
  role=$(g3kubectl describe serviceaccount $saName | grep Annotations | sed -n "s/^.*:role\/\(\S*\)$/\1/p")
  policyName=$(gen3_aws_run aws iam list-role-policies --role-name $role | jq -r .PolicyNames[0])
  gen3_aws_run aws iam delete-role-policy --role-name $role --policy-name $policyName
  gen3_aws_run aws iam delete-role --role-name $role
  g3kubectl delete serviceaccount $saName

  # Delete creds
  credsFile="$(gen3_secrets_folder)/g3auto/dcfbucketreplicate/creds.json"
  rm -f $credsFile
}

command="$1"
shift
case "$command" in
  'create')
    gen3_dcf_create_aws_batch "$@"
    ;;
  'cleanup')
    gen3_dcf_batch_cleanup "$@"
    ;;
  'status')
    gen3_dcf_replicate_generating_status
    ;;
  'list' )
    gen3_dcf_bucket_replicate_list
    ;;
  'help')
    gen3_dcf_bucket_replicate_help "$@"
    ;;
  *)
    gen3_dcf_bucket_replicate_help
    ;;
esac
exit $?