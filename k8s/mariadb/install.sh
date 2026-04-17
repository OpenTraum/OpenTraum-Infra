#!/bin/bash

NAMESPACE="opentraum"

# Helm 저장소 추가
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install opentraum-mariadb bitnami/mariadb \
  --namespace ${NAMESPACE} \
  --version 20.5.5 \
  -f custom-values.yaml
