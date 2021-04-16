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

docker image build --file Dockerfile.base --cache-from "${registry}/base" --tag "${registry}/base" .
docker image push "${registry}/base"
get_manifest "${registry}" base >"${TEMP}/manifest.json"
get_config "${registry}" base >"${TEMP}/config.json"

echo "Mounting layers"
# shellcheck disable=SC2002
cat "${TEMP}/manifest.json" | mount_layer_blobs "${registry}" join base

for LAYER in docker docker-compose helm kubectl; do
    docker image build --file "Dockerfile.${LAYER}" --cache-from "${registry}/${LAYER}" --tag "${registry}/${LAYER}" .
    docker image push "${registry}/${LAYER}"

    manifest_file="${TEMP}/${LAYER}.manifest.json"
    get_manifest "${registry}" "${LAYER}" >"${manifest_file}"
    
    layer_blob="$(jq --raw-output '.layers[-1].digest' "${manifest_file}")"
    layer_size="$(jq --raw-output '.layers[-1].size' "${manifest_file}")"
    # shellcheck disable=SC2002
    config_blob="$(cat "${manifest_file}" | get_config_digest)"

    config_file="${TEMP}/${LAYER}.config.json"
    get_config_by_digest "${registry}" "${LAYER}" "${config_blob}" >"${config_file}"

    layer_command=$(jq --raw-output '.history[-1]' "${config_file}")
    layer_diff=$(jq --raw-output '.rootfs.diff_ids[-1]' "${config_file}")

    echo "Mount layer"
    mount_digest "${registry}" join "${LAYER}" "${layer_blob}"

    echo "Patch manifest"
    mv "${TEMP}/manifest.json" "${TEMP}/manifest.json.bak"
    # shellcheck disable=SC2002
    cat "${TEMP}/manifest.json.bak" | \
        append_layer_to_manifest "${layer_blob}" "${layer_size}" \
    >"${TEMP}/manifest.json"

    echo "Patch config"
    mv "${TEMP}/config.json" "${TEMP}/config.json.bak"
    # shellcheck disable=SC2002
    cat "${TEMP}/config.json.bak" | \
        append_layer_to_config "${layer_diff}" "${layer_command}" \
    >"${TEMP}/config.json"
done

echo "Upload config"
# shellcheck disable=SC2002
cat "${TEMP}/config.json" | upload_config "${registry}" join

echo "Update and upload manifest"
# shellcheck disable=SC2002
cat "${TEMP}/manifest.json" | \
    update_config "$(cat "${TEMP}/config.json" | get_blob_metadata)" | \
    upload_manifest "${registry}" join
