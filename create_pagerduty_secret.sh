#!/bin/bash

set -e
set -u

kubectl create secret -n monitoring generic pagerduty-sre-secret --from-literal=apiKey=$1
kubectl create secret -n monitoring generic alertmanager-tmpl-secrets --from-literal=secrets="{{ define \"pagerduty.sre.integrationKey\" }}$1{{ end}}"
