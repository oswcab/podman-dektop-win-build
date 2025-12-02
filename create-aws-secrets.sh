#!/bin/bash

kubectl create secret generic 'aws-ssh-key' \
  --from-file=id_rsa="${AWS_KEY_PAIR_PEM}" \
  --namespace 'multi-platform-controller'
kubectl label secret 'aws-ssh-key' \
  'build.appstudio.redhat.com/multi-platform-secret=true' \
  --namespace 'multi-platform-controller'

kubectl create secret generic 'aws-account' \
  --from-literal=access-key-id="${AWS_ACCESS_KEY_ID}" \
  --from-literal=secret-access-key="${AWS_SECRET_ACCESS_KEY}" \
  --namespace 'multi-platform-controller'
kubectl label secret 'aws-account' \
  'build.appstudio.redhat.com/multi-platform-secret=true' \
  --namespace 'multi-platform-controller'
