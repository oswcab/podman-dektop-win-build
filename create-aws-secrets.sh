#!/bin/bash

mkdir /tmp/ssh-mpc
ssh-keygen -t rsa -b 4096 -N "" -f '/tmp/ssh-mpc/id_rsa'

kubectl create secret generic 'aws-ssh-key' \
  --from-file=id_rsa='/tmp/ssh-mpc/id_rsa' \
  --namespace 'multi-platform-controller'
kubectl create secret generic 'aws-account' \
  --from-literal=access-key-id="${AWS_ACCESS_KEY_ID}" \
  --from-literal=secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
  --namespace 'multi-platform-controller'
