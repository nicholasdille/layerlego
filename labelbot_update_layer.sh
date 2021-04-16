#!/bin/bash
set -o errexit

registry=127.0.0.1:5000
if test "$(docker container ls --filter name=registry | wc -l)" -eq 1; then
    docker container run --detach --name registry --publish "${registry}:5000" registry
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

docker image build --file Dockerfile.labelbot --cache-from "${registry}/labelbot" --tag "${registry}/labelbot" .
docker image push "${registry}/labelbot"
get_manifest "${registry}" labelbot >"${TEMP}/manifest.json"
get_config "${registry}" labelbot >"${TEMP}/config.json"

cat "${TEMP}/manifest.json" | jq .

layer_index=$(
    cat "${TEMP}/config.json" | \
        get_layer_index_by_command "LABEL foo="
)
layer_index=$(( ${layer_index} + 1 ))
echo "label layer index: ${layer_index}"

empty_layer_offset=$(
    cat "${TEMP}/config.json" | \
        count_empty_layers_before_index "${layer_index}"
)
echo "empty layer offset: ${empty_layer_offset}"

layer_index=$(( ${layer_index} - ${empty_layer_offset} ))
echo "modify at: ${layer_index}"

layer_digest=$(
    cat "${TEMP}/manifest.json" | \
        get_layer_digest_by_index "${layer_index}"
)
echo "get layer digest: ${layer_digest}"

mkdir -p "${TEMP}/${layer_digest}"
get_blob "${registry}" labelbot "${layer_digest}" | tar -xzC "${TEMP}/${layer_digest}"
rm -rf "${TEMP}/${layer_digest}/bin/bash"
tar -czf "${TEMP}/labelbot.tar.gz" -C "${TEMP}/${layer_digest}" .
upload_blob "${registry}" labelbot "${TEMP}/labelbot.tar.gz" "${MEDIA_TYPE_LAYER}"

rootfs_digest=$(cat "${TEMP}/labelbot.tar.gz" | gunzip | sha256sum | cut -d' ' -f1)
cat "${TEMP}/config.json" | \
    replace_layer_in_config "${layer_index}" "${rootfs_digest}" \
    >"${TEMP}/new_config.json"

cat "${TEMP}/new_config.json" | \
    upload_config "${registry}" labelbot

layer_size=$(stat --format=%s "${TEMP}/labelbot.tar.gz")
layer_digest=$(sha256sum "${TEMP}/labelbot.tar.gz" | cut -d' ' -f1)
config_size=$(stat --format=%s "${TEMP}/new_config.json")
config_digest=$(head -c -1 "${TEMP}/new_config.json" | sha256sum | cut -d' ' -f1)
cat "${TEMP}/manifest.json" | \
    replace_layer_in_manifest "${layer_index}" "${layer_digest}" "${layer_size}" | \
    update_config "${config_digest}" "${config_size}" \
    >"${TEMP}/new_manifest.json"

cat "${TEMP}/new_manifest.json" | \
    upload_manifest "${registry}" labelbot update
