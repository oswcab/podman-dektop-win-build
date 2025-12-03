#!/bin/bash

[ -n "${AWS_KEY_PAIR_PEM}" ] || { echo "AWS_KEY_PAIR_PEM not found. Please export it"; exit 1; }
[ -n "${AWS_ACCESS_KEY_ID}" ] || { echo "AWS_ACCESS_KEY_ID not found. Please export it"; exit 1; }
[ -n "${AWS_SECRET_ACCESS_KEY}" ] || { echo "AWS_SECRET_ACCESS_KEY not found. Please export it"; exit 1; }

MPC_LABEL='build.appstudio.redhat.com/multi-platform-secret=true'
MPC_NS='multi-platform-controller'

kubectl create secret generic 'aws-ssh-key' \
  --from-file=id_rsa="${AWS_KEY_PAIR_PEM}" \
  --namespace "${MPC_NS}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl label secret 'aws-ssh-key' --namespace "${MPC_NS}" "${MPC_LABEL}"

kubectl create secret generic 'aws-account' \
  --from-literal=access-key-id="${AWS_ACCESS_KEY_ID}" \
  --from-literal=secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
  --namespace "${MPC_NS}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl label secret 'aws-account' --namespace "${MPC_NS}" "${MPC_LABEL}"
