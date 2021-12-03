#!/bin/bash
set -euo pipefail

#
# The following script provisions a local volume with one replica,
# then deploys a pod on a different node than the master volume and runs fio tests
# to measure StorageOS performance. The FIO tests that are run can be found
# here: https://github.com/storageos/dbench/blob/master/docker-entrypoint.sh
#
# In order to successfully execute the tests you will need to have:
#  - Kubernetes cluster with a minium of 3 nodes and 30 Gib space
#  - kubectl in the PATH - kubectl access to this cluster with
#    cluster-admin privileges - export KUBECONFIG as appropriate
#  - StorageOS CLI running as a pod in the cluster
#  - jq in the PATH 
#

# Define some colours for later
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Scenario: Remote Volume with a replica${NC}"
echo

# Checking if jq is in the PATH
if ! command -v jq &> /dev/null
then
    echo -e "${RED}jq could not be found. Please install jq and run the script again${NC}"
    exit
fi

# Checking if StorageOS Cli is running as a pod, if not the script will deploy it
CLI_VERSION="storageos/cli:v2.5.0"
STOS_NS="kube-system"
cli_pod=$(kubectl -n ${STOS_NS} get pod -lrun=cli --no-headers -ocustom-columns=_:.metadata.name)

if [ "${cli_pod}" != "cli" ]
then
    echo -e "${RED}StorageOS CLI pod not found. Deploying now${NC}"

    kubectl -n ${STOS_NS} run \
    --image ${CLI_VERSION} \
    --restart=Never                          \
    --env STORAGEOS_ENDPOINTS=storageos:5705 \
    --env STORAGEOS_USERNAME=$(kubectl -n ${STOS_NS} get secrets init-secret -oyaml | awk '/username:/ {print $2}' |  base64 --decode) \
    --env STORAGEOS_PASSWORD=$(kubectl -n ${STOS_NS} get secrets init-secret -oyaml | awk '/password:/ {print $2}' |  base64 --decode) \
    --command cli                            \
    -- /bin/sh -c "while true; do sleep 999999; done"
fi

sleep 5
SECONDS=0
TIMEOUT=30
while ! kubectl -n ${STOS_NS} get pod cli -otemplate="{{ .status.phase }}" 2>/dev/null| grep -q Running; do
  pod_status=$(kubectl -n ${STOS_NS} get pod cli -otemplate="{{ .status.phase }}" 2>/dev/null)
  if [ $SECONDS -gt $TIMEOUT ]; then
      echo "The pod cli didn't start after $TIMEOUT seconds" 1>&2
      echo -e "${RED}Pod: cli, is in ${pod_status}${NC} state."
      exit 1
  fi
  sleep 5
done

# Get the node name and id where the volume will get provisioned and attached on
# Using the StorageOS cli is guarantee that the node is running StorageOS
node_details=$(kubectl -n ${STOS_NS} exec cli -- storageos describe nodes -ojson | jq -r '[.[0].labels."kubernetes.io/hostname",.[0].id,.[1].labels."kubernetes.io/hostname",.[1].id]')
local_node_name=$(echo $node_details | jq -r '.[0]')
local_node_id=$(echo $node_details | jq -r '.[1]')

remote_node_id=$(echo $node_details | jq -r '.[3]')

pvc_prefix="$RANDOM"

# Create a temporary dir where the remote-volume-with-replica-fio.yaml will get created in
manifest_path=$(mktemp -d -t tmp-remote-fio-XXXX)

fio_job="remote-volume-with-replica-fio"
manifest="${manifest_path}/${fio_job}.yaml"
logs_path=$(mktemp -d -t fio-logs-XXXX)

# Create a 25 Gib StorageOS volume with one replica manifest
cat <<END >> $manifest
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${pvc_prefix}
  labels:
    storageos.com/hint.master: "${remote_node_id}"
    storageos.com/replicas: "1"
spec:
  storageClassName: fast
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 15Gi
---
END

# Create batch job for the FIO tests manifest
cat <<END >> $manifest
apiVersion: batch/v1
kind: Job
metadata:
  name: "${fio_job}"
spec:
  template:
    spec:
      nodeSelector:
        "kubernetes.io/hostname": ${local_node_name}
      containers:
      - name: "${fio_job}"
        image: storageos/dbench:latest
        imagePullPolicy: Always
        env:
          - name: DBENCH_MOUNTPOINT
            value: /data
        volumeMounts:
        - name: dbench-pv
          mountPath: /data
      restartPolicy: Never
      volumes:
      - name: dbench-pv
        persistentVolumeClaim:
          claimName: pvc-${pvc_prefix}
  backoffLimit: 4
END

# Deploying FIO Job
echo -e "${GREEN}Deploying the ${fio_job} Job${NC}"
# Create Job and PVC
kubectl create -f ${manifest}

echo -e "${GREEN}FIO tests started.${NC}"
echo -e "${GREEN}Waiting up to 7 minutes for the ${fio_job} Job to finish.${NC}"
echo

sleep 5
pod=$(kubectl get pod -l job-name=${fio_job} --no-headers -ocustom-columns=_:.metadata.name 2>/dev/null || :)
SECONDS=0
TIMEOUT=420
while ! kubectl get pod ${pod} -otemplate="{{ .status.phase }}" 2>/dev/null| grep -q Succeeded; do
  pod_status=$(kubectl get pod ${pod} -otemplate="{{ .status.phase }}" 2>/dev/null)
  if [ $SECONDS -gt $TIMEOUT ]; then
      echo "The pod $pod didn't succeed after $TIMEOUT seconds" 1>&2
      echo -e "${GREEN}Pod: ${pod}, is in ${pod_status}${NC} state."
      # Cleanup if job fails for any reason
      kubectl delete -f ${manifest}
      exit 1
  fi
  sleep 10
done

echo -e "${GREEN}${fio_job} Job finished successfully.${NC}"
echo

#  Gathering Logs and  printing out StorageOS performance
kubectl logs -f jobs/${fio_job} > ${logs_path}/${fio_job}.log
tail -n 7 ${logs_path}/${fio_job}.log
echo
echo -e "${GREEN}Removing ${fio_job} Job.${NC}"
# Deleting the Job to clean up the cluster
kubectl delete -f ${manifest}
echo

echo -e "${GREEN}Cleaning up${NC}"
rm -rf  "${manifest_path}" "${logs_path}"
