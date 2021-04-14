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
get_manifest base >"${TEMP}/manifest.json"
get_config base >"${TEMP}/config.json"

echo "Mounting layers"
cat "${TEMP}/manifest.json" | mount_layer_blobs join base

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

    echo "Mount layer"
    mount_digest join "${LAYER}" "${LAYER_BLOB}"

    echo "Patch manifest"
    mv "${TEMP}/manifest.json" "${TEMP}/manifest.json.bak"
    cat "${TEMP}/manifest.json.bak" | \
        jq '.layers += [{"mediaType": $type, "size": $size | tonumber, "digest": $digest}]' \
            --arg type "${MEDIA_TYPE_IMAGE}" \
            --arg digest "${LAYER_BLOB}" \
            --arg size "${LAYER_SIZE}" \
    >"${TEMP}/manifest.json"

    echo "Patch config"
    mv "${TEMP}/config.json" "${TEMP}/config.json.bak"
    cat "${TEMP}/config.json.bak" | \
        jq '.history += [$command | fromjson]' \
            --arg command "${LAYER_COMMAND}" | \
        jq '.rootfs.diff_ids += [$diff]' \
            --arg diff "${LAYER_DIFF}" \
    >"${TEMP}/config.json"
done

echo "Upload config"
cat "${TEMP}/config.json" | upload_config join

echo "Update and upload manifest"
cat "${TEMP}/manifest.json" | \
    update_config $(cat "${TEMP}/config.json" | get_blob_metadata) | \
    upload_manifest join
