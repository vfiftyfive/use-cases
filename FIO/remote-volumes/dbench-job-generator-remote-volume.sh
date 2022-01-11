#!/usr/bin/env bash 
set -euo pipefail

# Define job and source the script lib
job="remote-volume-without-replica-fio"
source ../lib/sh/functions.sh

#
# The following script provisions a volume with no replicas,
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

echo -e "${GREEN}Scenario: Remote Volume with no replica${NC}"
echo

check_for_jq

# Checking if StorageOS Cli is running as a pod, if not the script will deploy it
cli=$(get_cli_pod)
echo -e "${GREEN}CLI pod: ${cli}"

# Get the node name and id where the volume will get provisioned and attached on
# Using the StorageOS cli is guarantee that the node is running StorageOS
nodes_and_ids=($(get_storageos_nodes))
local_node_name=${nodes_and_ids[0]%~*} 
remote_node_id=${nodes_and_ids[1]#*~}
pvc_prefix="$RANDOM"

# Create a 25 Gib StorageOS volume with no replicas manifest
cat <<END >> "$manifest"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${pvc_prefix}
  labels:
    storageos.com/hint.master: "${remote_node_id}"
spec:
  storageClassName: storageos
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 15Gi
---
END

# Create batch job for the FIO tests manifest
cat <<END >> "$manifest"
apiVersion: batch/v1
kind: Job
metadata:
  name: "${job}"
spec:
  template:
    spec:
      nodeSelector:
        "kubernetes.io/hostname": ${local_node_name}
      containers:
      - name: "${job}"
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

run_or_die
