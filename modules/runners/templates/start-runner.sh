#!/bin/bash

# https://docs.aws.amazon.com/xray/latest/devguide/xray-api-sendingdata.html
# https://docs.aws.amazon.com/xray/latest/devguide/scorekeep-scripts.html
create_xray_start_segment() {
  START_TIME=$(date -d "$(uptime -s)" +%s)
  TRACE_ID=$1
  INSTANCE_ID=$2
  SEGMENT_ID=$(dd if=/dev/random bs=8 count=1 2>/dev/null | od -An -tx1 | tr -d ' \t\n')
  SEGMENT_DOC="{\"trace_id\": \"$TRACE_ID\", \"id\": \"$SEGMENT_ID\", \"start_time\": $START_TIME, \"in_progress\": true, \"name\": \"Runner\",\"origin\": \"AWS::EC2::Instance\", \"aws\": {\"ec2\":{\"instance_id\":\"$INSTANCE_ID\"}}}"
  HEADER='{"format": "json", "version": 1}'
  TRACE_DATA="$HEADER\n$SEGMENT_DOC"
  echo "$HEADER" > document.txt
  echo "$SEGMENT_DOC" >> document.txt
  UDP_IP="127.0.0.1"
  UDP_PORT=2000
  cat document.txt > /dev/udp/$UDP_IP/$UDP_PORT
  echo "$SEGMENT_DOC"
}

create_xray_success_segment() {
  local SEGMENT_DOC=$1
  if [ -z "$SEGMENT_DOC" ]; then
    echo "No segment doc provided"
    return
  fi
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq '. | del(.in_progress)')
  END_TIME=$(date +%s)
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq -c ". + {\"end_time\": $END_TIME}")
  HEADER="{\"format\": \"json\", \"version\": 1}"
  TRACE_DATA="$HEADER\n$SEGMENT_DOC"
  echo "$HEADER" > document.txt
  echo "$SEGMENT_DOC" >> document.txt
  UDP_IP="127.0.0.1"
  UDP_PORT=2000
  cat document.txt > /dev/udp/$UDP_IP/$UDP_PORT
  echo "$SEGMENT_DOC"
}

create_xray_error_segment() {
  local SEGMENT_DOC="$1"
  if [ -z "$SEGMENT_DOC" ]; then
    echo "No segment doc provided"
    return
  fi
  MESSAGE="$2"
  ERROR="{\"exceptions\": [{\"message\": \"$MESSAGE\"}]}"
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq '. | del(.in_progress)')
  END_TIME=$(date +%s)
  SEGMENT_DOC=$(echo "$SEGMENT_DOC" | jq -c ". + {\"end_time\": $END_TIME, \"error\": true, \"cause\": $ERROR }")
  HEADER="{\"format\": \"json\", \"version\": 1}"
  TRACE_DATA="$HEADER\n$SEGMENT_DOC"
  echo "$HEADER" > document.txt
  echo "$SEGMENT_DOC" >> document.txt
  UDP_IP="127.0.0.1"
  UDP_PORT=2000
  cat document.txt > /dev/udp/$UDP_IP/$UDP_PORT
  echo "$SEGMENT_DOC"
}

tag_instance_with_runner_id() {
  echo "Checking for .runner file to extract agent ID"

  if [[ ! -f "/opt/actions-runner/.runner" ]]; then
    echo "Warning: .runner file not found"
    return 0
  fi

  echo "Found .runner file, extracting agent ID"
  local agent_id
  agent_id=$(jq -r '.agentId' /opt/actions-runner/.runner 2>/dev/null || echo "")

  if [[ -z "$agent_id" || "$agent_id" == "null" ]]; then
    echo "Warning: Could not extract agent ID from .runner file"
    return 0
  fi

  echo "Tagging instance with GitHub runner agent ID: $agent_id"
  if aws ec2 create-tags \
    --region "$region" \
    --resources "$instance_id" \
    --tags Key=ghr:github_runner_id,Value="$agent_id"; then
    echo "Successfully tagged instance with agent ID: $agent_id"
    return 0
  else
    echo "Warning: Failed to tag instance with agent ID"
    return 0
  fi
}

mount_ephemeral_nvme_work_dir() {
  local work_dir="/opt/actions-runner/_work"
  mkdir -p "$work_dir"

  if mountpoint -q "$work_dir"; then
    chown "$run_as:" "$work_dir"
    return 0
  fi

  local blk_dir model dev
  for blk_dir in /sys/class/block/nvme*; do
    # Whole-disk NVMe namespaces omit the sysfs `partition` attribute present on nvme*n*p*.
    if [[ ! -e "$blk_dir" || -e "$blk_dir/partition" || ! -r "$blk_dir/device/model" ]]; then
      continue
    fi

    # Nitro exposes both EBS and instance-store volumes as /dev/nvme*n1 in
    # non-deterministic probe order; NVMe Identify Controller right-pads `model`
    # with spaces to 40 bytes.
    model=$(sed 's/[[:space:]]*$//' "$blk_dir/device/model")
    if [[ "$model" != "Amazon EC2 NVMe Instance Storage" ]]; then
      continue
    fi

    dev="/dev/$(basename "$blk_dir")"
    if [[ ! -b "$dev" ]]; then
      continue
    fi

    if findmnt -rn -S "$dev" >/dev/null \
      || [[ -n "$(lsblk -rn -o MOUNTPOINT "$dev" | tr -d '[:space:]')" ]] \
      || [[ -n "$(ls -A "$blk_dir/holders" 2>/dev/null)" ]]; then
      continue
    fi

    echo "Formatting ephemeral NVMe instance storage $dev for $work_dir"
    mkfs.ext4 -q -m 0 -F -E lazy_itable_init=1,lazy_journal_init=1,nodiscard "$dev"
    mount -o noatime "$dev" "$work_dir"
    # Fresh ext4 creates a 0700 root:root lost+found that fails unprivileged workspace scans.
    rmdir "$work_dir/lost+found" 2>/dev/null || true
    break
  done

  chown "$run_as:" "$work_dir"
}

cleanup() {
  local exit_code="$1"
  local error_location="$2"
  local error_lineno="$3"

  if [ "$exit_code" -ne 0 ]; then
    echo "ERROR: runner-start-failed with exit code $exit_code occurred on $error_location"
    create_xray_error_segment "$SEGMENT" "runner-start-failed with exit code $exit_code occurred on $error_location - $error_lineno"
  fi
  # Ensure background CloudWatch agent startup finishes before flushing logs or stopping the unit.
  if [[ -n "$cloudwatch_pid" ]]; then
    wait "$cloudwatch_pid" || echo "Warning: CloudWatch agent setup exited with status $?"
  fi
  # allows to flush the cloud watch logs and traces
  sleep 10
  if [ "$agent_mode" = "ephemeral" ] || [ "$exit_code" -ne 0 ]; then
    echo "Stopping CloudWatch service"
    systemctl stop amazon-cloudwatch-agent.service || true
    echo "Terminating instance"
    aws ec2 terminate-instances \
      --instance-ids "$instance_id" \
      --region "$region" \
      || true
  fi
}

cloudwatch_pid=""
trap 'cleanup $? $LINENO $BASH_LINENO' EXIT

echo "Retrieving TOKEN from AWS API"
token=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 180" || true)
if [ -z "$token" ]; then
  retrycount=0
  until [ -n "$token" ]; do
    echo "Failed to retrieve token. Retrying in 1 second."
    sleep 1
    token=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 180" || true)
    retrycount=$((retrycount + 1))
    if [ $retrycount -gt 180 ]; then
      break
    fi
  done
fi

identity_doc=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/dynamic/instance-identity/document)
ami_id=$(jq -r .imageId <<< "$identity_doc")
region=$(jq -r .region <<< "$identity_doc")
echo "Retrieved REGION from AWS API ($region)"
instance_id=$(jq -r .instanceId <<< "$identity_doc")
echo "Retrieved INSTANCE_ID from AWS API ($instance_id)"
instance_type=$(jq -r .instanceType <<< "$identity_doc")
availability_zone=$(jq -r .availabilityZone <<< "$identity_doc")

%{ if metadata_tags == "enabled" }
environment=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:environment)
ssm_config_path=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:ssm_config_path)
runner_name_prefix=$(curl -fs -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:runner_name_prefix || echo "")
xray_trace_id=$(curl -fs -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/tags/instance/ghr:trace_id || echo "")

%{ else }
tags=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$instance_id")
echo "Retrieved tags from AWS API ($tags)"

environment=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:environment") | .Value')
ssm_config_path=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:ssm_config_path") | .Value')
runner_name_prefix=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:runner_name_prefix") | .Value' || echo "")
xray_trace_id=$(echo "$tags" | jq -r '.Tags[]  | select(.Key == "ghr:trace_id") | .Value' || echo "")

%{ endif }

echo "Retrieved ghr:environment tag - ($environment)"
echo "Retrieved ghr:ssm_config_path tag - ($ssm_config_path)"
echo "Retrieved ghr:runner_name_prefix tag - ($runner_name_prefix)"

parameters=$(aws ssm get-parameters-by-path --path "$ssm_config_path" --region "$region" --query "Parameters[*].{Name:Name,Value:Value}")
echo "Retrieved parameters from AWS SSM ($parameters)"

run_as=$(echo "$parameters" | jq -r '.[] | select(.Name == "'$ssm_config_path'/run_as") | .Value')
echo "Retrieved /$ssm_config_path/run_as parameter - ($run_as)"

enable_cloudwatch_agent=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_cloudwatch") | .Value')
echo "Retrieved /$ssm_config_path/enable_cloudwatch parameter - ($enable_cloudwatch_agent)"

agent_mode=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/agent_mode") | .Value')
echo "Retrieved /$ssm_config_path/agent_mode parameter - ($agent_mode)"

disable_default_labels=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/disable_default_labels") | .Value')
echo "Retrieved /$ssm_config_path/disable_default_labels parameter - ($disable_default_labels)"

enable_jit_config=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_jit_config") | .Value')
echo "Retrieved /$ssm_config_path/enable_jit_config parameter - ($enable_jit_config)"

token_path=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/token_path") | .Value')
echo "Retrieved /$ssm_config_path/token_path parameter - ($token_path)"

if [[ "$xray_trace_id" != "" ]]; then
  # run xray service
  curl https://s3.us-east-2.amazonaws.com/aws-xray-assets.us-east-2/xray-daemon/aws-xray-daemon-linux-3.x.zip -o aws-xray-daemon-linux-3.x.zip
  unzip aws-xray-daemon-linux-3.x.zip -d aws-xray-daemon-linux-3.x
  chmod +x ./aws-xray-daemon-linux-3.x/xray
  ./aws-xray-daemon-linux-3.x/xray -o -n "$region" &


  SEGMENT=$(create_xray_start_segment "$xray_trace_id" "$instance_id")
  echo "$SEGMENT"
fi

if [[ "$enable_cloudwatch_agent" == "true" ]]; then
  echo "Cloudwatch is enabled"
  amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:$ssm_config_path/cloudwatch_agent_config_runner" &
  cloudwatch_pid=$!
fi

## Configure the runner

echo "Get GH Runner config from AWS SSM"
config=$(aws ssm get-parameter --name "$token_path"/"$instance_id" --with-decryption --region "$region" | jq -r ".Parameter | .Value")
while [[ -z "$config" ]]; do
  echo "Waiting for GH Runner config to become available in AWS SSM"
  sleep 1
  config=$(aws ssm get-parameter --name "$token_path"/"$instance_id" --with-decryption --region "$region" | jq -r ".Parameter | .Value")
done

echo "Delete GH Runner token from AWS SSM"
aws ssm delete-parameter --name "$token_path"/"$instance_id" --region "$region"

if [ -z "$run_as" ]; then
  echo "No user specified, using default ec2-user account"
  run_as="ec2-user"
fi

if [[ "$run_as" == "root" ]]; then
  echo "run_as is set to root - export RUNNER_ALLOW_RUNASROOT=1"
  export RUNNER_ALLOW_RUNASROOT=1
fi

# Prebuilt AMIs set /opt/actions-runner ownership at build time; recurse only
# when $run_as differs from the baked owner to avoid hydrating thousands of
# cold-EBS inodes on boot.
if [[ "$(stat -c '%U' /opt/actions-runner)" != "$run_as" ]]; then
  chown -R "$run_as:" /opt/actions-runner
else
  for path in /opt/actions-runner/.env /opt/actions-runner/hook_job_started.sh /opt/actions-runner/hook_job_completed.sh; do
    if [[ -e "$path" ]]; then
      chown "$run_as:" "$path"
    fi
  done
fi

mount_ephemeral_nvme_work_dir

info_arch=$(uname -p)
info_os=$( ( lsb_release -ds || cat /etc/*release || uname -om ) 2>/dev/null | head -n1 | cut -d "=" -f2- | tr -d '"')

tee /opt/actions-runner/.setup_info <<EOL
[
  {
    "group": "Operating System",
    "detail": "Distribution: $info_os\nArchitecture: $info_arch"
  },
  {
    "group": "Runner Image",
    "detail": "AMI id: $ami_id"
  },
  {
    "group": "EC2",
    "detail": "Instance type: $instance_type\nAvailability zone: $availability_zone"
  }
]
EOL
chown "$run_as:" /opt/actions-runner/.setup_info

## Start the runner
echo "Starting runner after $(awk '{print int($1/3600)":"int(($1%3600)/60)":"int($1%60)}' /proc/uptime)"
echo "Starting the runner as user $run_as"

# configure the runner if the runner is non ephemeral or jit config is disabled
if [[ "$enable_jit_config" == "false" || $agent_mode != "ephemeral" ]]; then
  echo "Configure GH Runner as user $run_as"
  if [[ "$disable_default_labels" == "true" ]]; then
      extra_flags="--no-default-labels"
  else
      extra_flags=""
  fi
  sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./config.sh $${extra_flags} --unattended --name "$runner_name_prefix$instance_id" --work "_work" $${config}

  # Tag instance with GitHub runner agent ID for non-JIT runners
  tag_instance_with_runner_id
fi

create_xray_success_segment "$SEGMENT"
if [[ $agent_mode = "ephemeral" ]]; then
  echo "Starting the runner in ephemeral mode"

  if [[ "$enable_jit_config" == "true" ]]; then
    echo "Starting with JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh --jitconfig $${config}
  else
    echo "Starting without JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh
  fi
  echo "Runner has finished"
else
  echo "Installing the runner as a service"
  ./svc.sh install "$run_as"
  echo "Starting the runner in persistent mode"
  ./svc.sh start
fi
