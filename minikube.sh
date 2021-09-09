#!/bin/bash
set -eu

minikube start --driver=kvm2 --memory=6G --cpus=2 --kuberetes-version=$1
