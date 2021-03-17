#!/bin/bash

REGISTRY=127.0.0.1:5000
if test "$(docker container ls --filter name=registry | wc -l)" -eq 1; then
    docker container run --detach --name registry --publish "${REGISTRY}:5000" registry
fi

# https://dille.name/blog/2018/08/19/how-to-reduce-the-build-time-of-a-monolithic-docker-image/

docker image build --file Dockerfile.base --cache-from "${REGISTRY}/base" --tag "${REGISTRY}/base" .
docker image push "${REGISTRY}/base"

for LAYER in docker docker-compose helm kubectl; do
    docker image build --file "Dockerfile.${LAYER}" --cache-from "${REGISTRY}/${LAYER}" --tag "${REGISTRY}/${LAYER}" .
    docker image push "${REGISTRY}/${LAYER}"

    MANIFEST_FILE=/tmp/docker.manifest.json
    curl "http://${REGISTRY}/v2/${LAYER}/manifests/latest" \
        --silent \
        --header "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        --output "${MANIFEST_FILE}"
    #cat "${MANIFEST_FILE}" | jq
    LAYER_BLOB=$(jq --raw-output '.layers[-1].digest' <"${MANIFEST_FILE}")
    CONFIG_BLOB=$(jq --raw-output '.config.digest' <"${MANIFEST_FILE}")

    CONFIG_FILE=/tmp/docker.config.json
    curl "http://${REGISTRY}/v2/${LAYER}/blobs/${CONFIG_BLOB}" \
        --silent \
        --header "Accept: application/vnd.docker.container.image.v1+json" \
        --output "${CONFIG_FILE}"
    #cat "${CONFIG_FILE}" | jq

    jq --raw-output '.history[-1].created_by' "${CONFIG_FILE}"

    #curl "http://${REGISTRY}/v2/${LAYER}/blobs/${LAYER_BLOB}" \
    #        --silent \
    #        --header "Accept: application/vnd.docker.image.rootfs.diff.tar.gzip" | \
    #    tar tvz

    # Append layer in manifest
    # Append rootfs in config
    # Append commands in history in config
    # Mount layers to new image
    # Upload manifest
done
