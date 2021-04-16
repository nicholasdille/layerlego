#!/bin/bash
set -o errexit

REGISTRY=127.0.0.1:5000
if test "$(docker container ls --filter name=registry | wc -l)" -eq 1; then
    docker container run --detach --name registry --publish "${REGISTRY}:5000" registry
fi

source "lib/common.sh"
source "lib/auth.sh"
source "lib/distribution.sh"
source "lib/layerlego.sh"

TEMP="$(mktemp -d)"
function cleanup() {
    test -d "${TEMP}" && rm -rf "${TEMP}"
}
trap cleanup EXIT

docker image build --file Dockerfile.labelbot --cache-from "${REGISTRY}/labelbot" --tag "${REGISTRY}/labelbot" .
docker image push "${REGISTRY}/labelbot"
get_manifest "${REGISTRY}" labelbot >"${TEMP}/manifest.json"
get_config "${REGISTRY}" labelbot >"${TEMP}/config.json"

LAYER_DIGEST=$(
    cat "${TEMP}/manifest.json" | \
        jq --raw-output '.layers[-1].digest'
)
get_blob "${REGISTRY}" labelbot "${LAYER_DIGEST}" >"${TEMP}/${LAYER_DIGEST}"
cat "${TEMP}/${LAYER_DIGEST}" | sha256sum
cat "${TEMP}/${LAYER_DIGEST}" | gunzip | sha256sum
mkdir -p "${TEMP}/labelbot"
echo "bar" >"${TEMP}/labelbot/foo"
tar -czf "${TEMP}/labelbot.tar.gz" "${TEMP}/labelbot"
upload_blob "${REGISTRY}" labelbot "${TEMP}/labelbot.tar.gz" "${MEDIA_TYPE_LAYER}"

LAYER_INDEX=$(
    cat "${TEMP}/config.json" | \
        get_layer_index_by_command "LABEL foo="
)
echo "label layer index: ${LAYER_INDEX}"

EMPTY_LAYER_OFFSET=$(
    cat "${TEMP}/config.json" | \
        count_empty_layers_before_index "${LAYER_INDEX}"
)
echo "empty layer offset: ${EMPTY_LAYER_OFFSET}"

LAYER_INDEX=$(( ${LAYER_INDEX} - ${EMPTY_LAYER_OFFSET} + 1 ))
echo "insert at: ${LAYER_INDEX}"

ROOTFS_DIGEST=$(cat "${TEMP}/labelbot.tar.gz" | gunzip | sha256sum | cut -d' ' -f1)
cat "${TEMP}/config.json" | \
    insert_layer_in_config "${LAYER_INDEX}" "${ROOTFS_DIGEST}" \
    >"${TEMP}/new_config.json"

cat "${TEMP}/new_config.json" | \
    upload_config "${REGISTRY}" labelbot

LAYER_SIZE=$(stat --format=%s "${TEMP}/labelbot.tar.gz")
LAYER_DIGEST=$(sha256sum "${TEMP}/labelbot.tar.gz" | cut -d' ' -f1)
CONFIG_SIZE=$(stat --format=%s "${TEMP}/new_config.json")
CONFIG_DIGEST=$(head -c -1 "${TEMP}/new_config.json" | sha256sum | cut -d' ' -f1)
cat "${TEMP}/manifest.json" | \
    insert_layer_in_manifest "${LAYER_INDEX}" "${LAYER_DIGEST}" "${LAYER_SIZE}" | \
    update_config "${CONFIG_DIGEST}" "${CONFIG_SIZE}" \
    >"${TEMP}/new_manifest.json"

cat "${TEMP}/new_manifest.json" | \
    upload_manifest "${REGISTRY}" labelbot new
