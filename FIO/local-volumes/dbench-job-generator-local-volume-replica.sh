#!/usr/bin/env bash
set -euo pipefail

job="local-volume-with-replica-fio"
source ../lib/sh/functions.sh

#
# The following script provisions a volume with a replica,
# then deploys a pod on the same node as the master volume and runs fio tests
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

echo -e "${GREEN}Scenario: Local Volume with a replica${NC}"
echo

check_for_jq

# Checking if StorageOS Cli is running as a pod, if not the script will deploy it
cli=$(get_cli_pod)
echo -e "${GREEN}CLI pod: ${cli}"

# Get the node name and id where the volume will get provisioned and attached on
# Using the StorageOS cli is guarantee that the node is running StorageOS
nodes_and_ids=$((get_storageos_nodes))
node_name=${nodes_and_ids[0]#*~}
node_id=${nodes_and_ids[0]%~*}
pvc_prefix="$RANDOM"

# Create a 25 Gib StorageOS volume with one replica manifest
cat <<END >> "$manifest"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-${pvc_prefix}-1
  labels:
    storageos.com/hint.master: "${node_id}"
    storageos.com/replicas: "1"
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
        "kubernetes.io/hostname": ${node_name}
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
          claimName: pvc-${pvc_prefix}-1
  backoffLimit: 4
END

run_or_die
