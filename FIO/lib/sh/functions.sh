#!/usr/bin/env bash
set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

CLI_VERSION="storageos/cli:v2.5.0" # Version of the CLI to run  
STOS_NS="storageos" # Namespace of the Ondat cluster

manifest_path=$(mktemp -d -t "$job-XXXX")
logs_path=$(mktemp -d -t "$job-XXXX")

# Create a temporary dir where the local-volume-without-replica-fio.yaml will get created in
manifest="${manifest_path}/${job}.yaml"

function cleanup { 
    echo
    echo -e "${GREEN}Removing $job Job.${NC}"
    # Deleting the Job to clean up the cluster
    kubectl delete -f "$manifest"
    rm -rf "${manifest_path}" "${logs_path}" 
}
trap cleanup EXIT

function check_for_jq {
  if ! command -v jq &> /dev/null
  then
    echo -e "${RED}jq could not be found. Please install jq and run the script again${NC}"
    exit 1
  fi
}

function get_cli_pod {
  # Checking if StorageOS Cli is running as a pod, if not the script will deploy it
  local cli
  cli=$(kubectl -n ${STOS_NS} get pod --no-headers -ocustom-columns=_:.metadata.name -lapp=storageos-cli)

  if [ -z "${cli}" ]
  then
      echo -e "${RED}StorageOS CLI pod not found. Deploying now${NC}"

      kubectl -n ${STOS_NS} run \
      --image ${CLI_VERSION} \
      --restart=Never                          \
      --labels app=storageos-cli               \
      --env STORAGEOS_ENDPOINTS=storageos:5705 \
      --env STORAGEOS_USERNAME="$(kubectl -n ${STOS_NS} get secrets storageos-api -oyaml | awk '/username:/ {print $2}' |  base64 --decode)" \
      --env STORAGEOS_PASSWORD="$(kubectl -n ${STOS_NS} get secrets storageos-api -oyaml | awk '/password:/ {print $2}' |  base64 --decode)" \
      --command "storageos-cli-$RANDOM"                            \
      -- /bin/sh -c "while true; do sleep 999999; done"
  sleep 5
  fi

  SECONDS=0
  TIMEOUT=60
  while ! kubectl -n ${STOS_NS} get pod --no-headers -ocustom-columns=_:.status.phase -lapp=storageos-cli 2>/dev/null | grep -q 'Running'; do
    local pod_status
    pod_status=$(kubectl -n ${STOS_NS} get pod --no-headers -ocustom-columns=_:.status.phase -lapp=storageos-cli 2>/dev/null)
    if [ $SECONDS -gt $TIMEOUT ]; then
        echo "The cli pod didn't start after $TIMEOUT seconds" 1>&2
        echo -e "${RED}Pod: cli, is in ${pod_status}${NC} state."
        exit 1
    fi
    sleep 5
  done
  echo "$cli"
}

function run_or_die {
  echo -e "${GREEN}Deploying the $job Job${NC}"
  kubectl create -f "$manifest"
  
  echo -e "${GREEN}FIO tests started.${NC}"
  echo -e "${GREEN}Waiting up to 7 minutes for the $job Job to finish.${NC}"
  echo
  
  sleep 5

  pod=$(kubectl get pod -l job-name="${job}" --no-headers -ocustom-columns=_:.metadata.name 2>/dev/null || :)
  SECONDS=0
  TIMEOUT=420
  while ! kubectl get pod "${pod}" -otemplate="{{ .status.phase }}" 2>/dev/null| grep -q Succeeded; do
    pod_status=$(kubectl get pod "${pod}" -otemplate="{{ .status.phase }}" 2>/dev/null)
    if [ $SECONDS -gt $TIMEOUT ]; then
        echo "The pod $pod didn't succeed after $TIMEOUT seconds" 1>&2
        echo -e "${GREEN}Pod: ${pod}, is in ${pod_status}${NC} state."
        # Cleanup if job fails for any reason
        kubectl delete -f "${manifest}"
        exit 1
    fi
    sleep 10
  done

  echo -e "${GREEN}$job Job finished successfully.${NC}"
  echo

#  Gathering Logs and  printing out StorageOS performance
kubectl logs -f "jobs/$job" > "${logs_path}/$job.log"
tail -n 7 "$logs_path/$job.log"
echo
}

function get_storageos_nodes {
  # Get the node name and id where the volume will get provisioned and attached on
  # Using the StorageOS cli is guarantee that the node is running StorageOS
  # Return value is of format "node_name~node_id node2_name~node2_id" 
  local node_details
  local cli
  cli=$(get_cli_pod)
  node_details=$(kubectl -n "${STOS_NS}" exec "$cli" -- storageos describe nodes -ojson | jq -jr '.[]|(.labels."kubernetes.io/hostname","~",.id," ")')
  echo "$node_details"
}
