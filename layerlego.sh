#!/bin/bash
set -o errexit

REGISTRY=127.0.0.1:5000
if test "$(docker container ls --filter name=registry | wc -l)" -eq 1; then
    docker container run --detach --name registry --publish "${REGISTRY}:5000" registry
fi

source "lib/distribution.sh"
source "lib/layerlego.sh"

TEMP="$(mktemp -d)"
function cleanup() {
    test -d "${TEMP}" && rm -rf "${TEMP}"
}
trap cleanup EXIT

docker image build --file Dockerfile.base --cache-from "${REGISTRY}/base" --tag "${REGISTRY}/base" .
docker image push "${REGISTRY}/base"
get_manifest base >"${TEMP}/base.manifest.json"
get_config base >"${TEMP}/base.config.json"

echo "Mounting layers"
cat "${TEMP}/base.manifest.json" | mount_layer_blobs join base
echo "Upload config"
cat "${TEMP}/base.config.json" | upload_config join
echo "Update and upload manifest"
cat "${TEMP}/base.manifest.json" | \
    update_config $(cat "${TEMP}/base.config.json" | get_blob_metadata) | \
    upload_manifest join

exit

#for LAYER in docker docker-compose helm kubectl; do
for LAYER in docker; do
    docker image build --file "Dockerfile.${LAYER}" --cache-from "${REGISTRY}/${LAYER}" --tag "${REGISTRY}/${LAYER}" .
    docker image push "${REGISTRY}/${LAYER}"

    MANIFEST_FILE="${TEMP}/${LAYER}.manifest.json"
    get_manifest "${LAYER}" >"${MANIFEST_FILE}"
    
    LAYER_BLOB="$(jq --raw-output '.layers[-1].digest' "${MANIFEST_FILE}")"
    LAYER_SIZE="$(jq --raw-output '.layers[-1].size' "${MANIFEST_FILE}")"
    CONFIG_BLOB="$(cat "${MANIFEST_FILE}" | get_config_digest)"

    CONFIG_FILE="${TEMP}/${LAYER}.config.json"
    get_config_by_digest "${LAYER}" "${CONFIG_BLOB}" >"${CONFIG_FILE}"

    LAYER_COMMAND=$(jq --raw-output '.history[-1]' "${CONFIG_FILE}")
    LAYER_DIFF=$(jq --raw-output '.rootfs.diff_ids[-1]' "${CONFIG_FILE}")

    # Append layer in manifest
    cat "${TEMP}/base.manifest.json" | \
        jq '.layers += [{"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip", "size": $size | tonumber, "digest": $digest}]' \
            --arg digest "${LAYER_BLOB}" \
            --arg size "${LAYER_SIZE}"

    # Append commands in history in config
    # Append rootfs in config
    cat "${TEMP}/base.config.json" | \
        jq '.history += [$command | fromjson]' \
            --arg command "${LAYER_COMMAND}" | \
        jq '.rootfs.diff_ids += [$diff]' \
            --arg diff "${LAYER_DIFF}"

    # Mount layers to new image
    #   POST /v2/<image>/blobs/uploads/?mount=<digest>&from=<source_image>
    # Upload config
    #   PUT <location>&digest=<digest>
    #   Content-Type: application/vnd.docker.container.image.v1+json
    # Upload manifest
    #   PUT /v2/<image>/manifests/<tag>
    #   Content-Type: application/vnd.docker.distribution.manifest.v2+json
done

# Build ${REGISTRY}/final:latest
