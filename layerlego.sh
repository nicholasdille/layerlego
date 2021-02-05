#!/bin/bash

REGISTRY=127.0.0.1:5000
if test "$(docker container ls --filter name=registry | wc -l)" -eq 1; then
    docker container run --detach --name registry --publish "${REGISTRY}:5000" registry
fi

docker image build --file Dockerfile.base --tag "${REGISTRY}/base" .
docker image push "${REGISTRY}/base"

for LAYER in docker docker-compose golang helm kubectl; do
    docker image build --file "Dockerfile.${LAYER}" --tag "${REGISTRY}/${LAYER}" .
    docker image push "${REGISTRY}/${LAYER}"
done

MANIFEST_FILE=/tmp/docker.manifest.json
curl "http://${REGISTRY}/v2/docker/manifests/latest" \
    --silent \
    --header "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    --output "${MANIFEST_FILE}"
#cat "${MANIFEST_FILE}" | jq
LAYER_BLOB=$(jq --raw-output '.layers[-1].digest' <"${MANIFEST_FILE}")
CONFIG_BLOB=$(jq --raw-output '.config.digest' <"${MANIFEST_FILE}")

CONFIG_FILE=/tmp/docker.config.json
curl "http://${REGISTRY}/v2/docker/blobs/${CONFIG_BLOB}" \
    --silent \
    --header "Accept: application/vnd.docker.container.image.v1+json" \
    --output "${CONFIG_FILE}"
#cat "${CONFIG_FILE}" | jq

jq --raw-output '.history[-1].created_by' "${CONFIG_FILE}"

curl "http://${REGISTRY}/v2/docker/blobs/${LAYER_BLOB}" \
        --silent \
        --header "Accept: application/vnd.docker.image.rootfs.diff.tar.gzip" | \
    tar tvz

