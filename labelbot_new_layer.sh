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

# shellcheck disable=SC2002
layer_index=$(
    cat "${TEMP}/config.json" | \
        get_layer_index_by_command "LABEL foo="
)
echo "label layer index: ${layer_index}"

# shellcheck disable=SC2002
empty_layer_offset=$(
    cat "${TEMP}/config.json" | \
        count_empty_layers_before_index "${layer_index}"
)
echo "empty layer offset: ${empty_layer_offset}"

layer_index=$(( layer_index - empty_layer_offset + 1 ))
echo "insert at: ${layer_index}"

# shellcheck disable=SC2002
layer_digest=$(
    cat "${TEMP}/manifest.json" | \
        get_layer_digest_by_index "${layer_index}"
)
get_blob "${REGISTRY}" labelbot "${layer_digest}" >"${TEMP}/${layer_digest}"
# shellcheck disable=SC2002
cat "${TEMP}/${layer_digest}" | sha256sum
# shellcheck disable=SC2002
cat "${TEMP}/${layer_digest}" | gunzip | sha256sum
mkdir -p "${TEMP}/labelbot"
pushd "${TEMP}/labelbot"
echo "bar" >"foo"
popd
tar -czf "${TEMP}/labelbot.tar.gz" -C "${TEMP}/labelbot" .
upload_blob "${REGISTRY}" labelbot "${TEMP}/labelbot.tar.gz" "${MEDIA_TYPE_LAYER}"

# shellcheck disable=SC2002
rootfs_digest=$(cat "${TEMP}/labelbot.tar.gz" | gunzip | sha256sum | cut -d' ' -f1)
# shellcheck disable=SC2002
cat "${TEMP}/config.json" | \
    insert_layer_in_config "${layer_index}" "${rootfs_digest}" \
    >"${TEMP}/new_config.json"

# shellcheck disable=SC2002
cat "${TEMP}/new_config.json" | \
    upload_config "${REGISTRY}" labelbot

layer_size=$(stat --format=%s "${TEMP}/labelbot.tar.gz")
layer_digest=$(sha256sum "${TEMP}/labelbot.tar.gz" | cut -d' ' -f1)
config_size=$(stat --format=%s "${TEMP}/new_config.json")
config_digest=$(head -c -1 "${TEMP}/new_config.json" | sha256sum | cut -d' ' -f1)
# shellcheck disable=SC2002
cat "${TEMP}/manifest.json" | \
    insert_layer_in_manifest "${layer_index}" "${layer_digest}" "${layer_size}" | \
    update_config "${config_digest}" "${config_size}" \
    >"${TEMP}/new_manifest.json"

# shellcheck disable=SC2002
cat "${TEMP}/new_manifest.json" | \
    upload_manifest "${REGISTRY}" labelbot new

echo "labelbot:latest"
get_manifest_layers "${REGISTRY}" labelbot
echo "labelbot:new"
get_manifest_layers "${REGISTRY}" labelbot new