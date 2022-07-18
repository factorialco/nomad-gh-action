#!/bin/sh

echo "Starting Nomad GitHub Action"

cd /

# :see_no_evil:
echo "$INPUT_ID_RSA" > /id_rsa

ruby << EOF
  require './deploy.rb'

  deploy = Deploy.new(
    ssh_user: '$INPUT_SSH_USER',
    ssh_host: '$INPUT_SSH_HOST',
    docker_image: '$INPUT_DOCKER_IMAGE',
    tag: '$INPUT_TAG',
    wait_status: '$INPUT_WAIT_STATUS',
    wait_task_group: '$INPUT_WAIT_TASK_GROUP',
    branch_name: '$INPUT_BRANCH_NAME',
    job_name: '$INPUT_JOB_NAME',
    nomad_url: '$INPUT_NOMAD_URL',
    job_related_service: '$INPUT_JOB_RELATED_SERVICE'
  )

  deploy.run!
EOF
