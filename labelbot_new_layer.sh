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

docker image build --file Dockerfile.labelbot --cache-from "${REGISTRY}/labelbot" --tag "${REGISTRY}/labelbot" .
docker image push "${REGISTRY}/labelbot"
get_manifest labelbot >"${TEMP}/manifest.json"
get_config labelbot >"${TEMP}/config.json"

LAYER_DIGEST=$(
    cat "${TEMP}/manifest.json" | \
        jq --raw-output '.layers[-1].digest'
)
# new function to get a blob
REPOSITORY=labelbot
curl -sH "Accept: ${MEDIA_TYPE_LAYER}" "${REGISTRY}/v2/${REPOSITORY}/blobs/${LAYER_DIGEST}" | sha256sum
curl -sH "Accept: ${MEDIA_TYPE_LAYER}" "${REGISTRY}/v2/${REPOSITORY}/blobs/${LAYER_DIGEST}" | gunzip | sha256sum
mkdir -p "${TEMP}/labelbot"
echo "bar" >"${TEMP}/labelbot/foo"
tar -czf "${TEMP}/labelbot.tar.gz" "${TEMP}/labelbot"
upload_blob labelbot "${TEMP}/labelbot.tar.gz" "${MEDIA_TYPE_LAYER}"

# new function for layer index with custom filter
LAYER_INDEX=$(
    cat "${TEMP}/config.json" | \
        jq '.history | to_entries[] | select(.value.created_by | startswith("LABEL foo=")) | .key'
)
echo "label layer index: ${LAYER_INDEX}"

# new function for layer count with optional filter
EMPTY_LAYER_OFFSET=$(
    cat "${TEMP}/config.json" | \
        jq --arg index "${LAYER_INDEX}" '.history | to_entries | map(select(.key < $index)) | map(select(.value.empty_layer == true)) | length'
)
echo "empty layer offset: ${EMPTY_LAYER_OFFSET}"

LAYER_INDEX=$(( ${LAYER_INDEX} - ${EMPTY_LAYER_OFFSET} + 1 ))
echo "insert at: ${LAYER_INDEX}"

# new function to add layer to config
ROOTFS_DIGEST=$(cat "${TEMP}/labelbot.tar.gz" | gunzip | sha256sum | cut -d' ' -f1)
cat "${TEMP}/config.json" | \
    jq '.rootfs.diff_ids = .rootfs.diff_ids[0:($index | tonumber)] + ["sha256:\($digest)"] + .rootfs.diff_ids[($index | tonumber):]' \
            --arg index "${LAYER_INDEX}" \
            --arg digest "${ROOTFS_DIGEST}" \
    >"${TEMP}/new_config.json"

cat "${TEMP}/new_config.json" | \
        upload_config labelbot

# new function to add layer to manifest
LAYER_SIZE=$(stat --format=%s "${TEMP}/labelbot.tar.gz")
LAYER_DIGEST=$(sha256sum "${TEMP}/labelbot.tar.gz" | cut -d' ' -f1)
CONFIG_SIZE=$(stat --format=%s "${TEMP}/new_config.json")
CONFIG_DIGEST=$(head -c -1 "${TEMP}/new_config.json" | sha256sum | cut -d' ' -f1)
cat "${TEMP}/manifest.json" | \
    jq '.layers = .layers[0:($index | tonumber)] + [{"mediaType": $type, "size": $size | tonumber, "digest": "sha256:\($digest)"}] + .layers[($index | tonumber):]' \
        --arg index "${LAYER_INDEX}" \
        --arg type "${MEDIA_TYPE_LAYER}" \
        --arg size "${LAYER_SIZE}" \
        --arg digest "${LAYER_DIGEST}" | \
    jq '.config = {"mediaType":$type,"size":$size | tonumber,"digest":"sha256:\($digest)"}' \
        --arg type "${MEDIA_TYPE_CONFIG}" \
        --arg size "${CONFIG_SIZE}" \
        --arg digest "${CONFIG_DIGEST}" \
    >"${TEMP}/new_manifest.json"

cat "${TEMP}/new_manifest.json" | \
    upload_manifest labelbot new
