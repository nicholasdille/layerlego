#!/bin/bash

function mount_config_blob() {
    local registry=$1
    local repository=$2
    local source=$3

    assert_pipeline_input "[EEE] [mount_config_blob] Failed to provide pipeline input. Usage: cat | mount_config_blob <registry> <repository> <repository>"
    assert_value "${registry}" "[EEE] [mount_config_blob] Failed to provide registry. Usage: cat | mount_config_blob <registry> <repository> <repository>"
    assert_value "${repository}" "[EEE] [mount_config_blob] Failed to provide repository. Usage: cat | mount_config_blob <registry> <repository> <repository>"
    assert_value "${source}" "[EEE] [mount_config_blob] Failed to provide source repository. Usage: cat | mount_config_blob <registry> <repository> <repository>"

    >&2 echo "[mount_config_blob] Mount config from ${source} to ${repository}"

    cat | \
        jq --raw-output '.config.digest' | \
        while read -r digest; do
            >&2 echo "[mount_blobs] Mount config digest ${digest}"
            mount_digest "${registry}" join base "${digest}"
        done
}

function mount_layer_blobs() {
    local registry=$1
    local repository=$2
    local source=$3

    assert_pipeline_input "[EEE] [mount_layer_blobs] Failed to provide pipeline input. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"
    assert_value "${registry}" "[EEE] [mount_layer_blobs] Failed to provide registry. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"
    assert_value "${repository}" "[EEE] [mount_layer_blobs] Failed to provide repository. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"
    assert_value "${source}" "[EEE] [mount_layer_blobs] Failed to provide source repository. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"

    >&2 echo "[mount_layer_blobs] Mount layer blobs from repository ${source} to repository ${repository}"

    cat | \
        jq --raw-output '.layers[].digest' | \
        while read -r digest; do
            >&2 echo "[mount_layer_blobs] Mount layer digest ${digest}"
            mount_digest "${registry}" "${repository}" "${source}" "${digest}"
        done
}

function mount_blobs() {
    local registry=$1
    local repository=$2
    local source=$3
    local tag=${4:-latest}

    assert_value "${registry}" "[EEE] [mount_blobs] Failed to provide registry. Usage: mount_blobs <registry> <repository> <repository> [<tag>]"
    assert_value "${repository}" "[EEE] [mount_blobs] Failed to provide repository. Usage: mount_blobs <registry> <repository> <repository> [<tag>]"
    assert_value "${source}" "[EEE] [mount_blobs] Failed to provide source repository. Usage: mount_blobs <registry> <repository> <repository> [<tag>]"

    >&2 echo "[mount_blobs] Mount config and all layers from ${source}:${tag} to ${repository}"

    local manifest
    manifest="$(get_manifest "${registry}" "${source}" "${tag}")"

    echo -n "${manifest}" | \
        mount_config_blob "${registry}" "${repository}" "${source}"
    
    echo -n "${manifest}" | \
        mount_layers_blobs "${registry}" "${repository}" "${source}"
}

function get_blob_metadata() {
    >&2 echo "[get_blob_metadata]"
    local blob
    blob="$(cat)"

    assert_pipeline_input "[EEE] [get_blob_metadata] Failed to provide pipeline input. Usage: cat | get_blob_metadata"

    local config_digest
    config_digest="sha256:$(echo -n "${blob}" | sha256sum | cut -d' ' -f1)"
    local config_size
    config_size="$(echo -n "${blob}" | wc -c)"

    echo "${config_digest} ${config_size}"
}

function update_config() {
    local digest=$1
    local size=$2

    assert_pipeline_input "[EEE] [update_config] Failed to provide pipeline input. Usage: cat | update_config <digest> <size>"
    assert_value "${digest}" "[EEE] [update_config] Failed to provide config digest. Usage: cat | update_config <digest> <size>"
    assert_value "${size}" "[EEE] [update_config] Failed to provide size. Usage: cat | update_config <digest> <size>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    >&2 echo "[update_config] digest=${digest} size=${size}"

    cat | \
        jq '.config.digest = $digest | .config.size = ($size | tonumber)' \
            --arg digest "${digest}" \
            --arg size "${size}"
}

function append_layer_to_manifest() {
    local digest=$1
    local size=$2
    local type=${3:-${MEDIA_type_LAYER}}

    assert_pipeline_input "[EEE] [append_layer_to_manifest] Failed to provide pipeline input. Usage: cat | update_config <digest> <size> [<type>]"
    assert_value "${digest}" "[EEE] [append_layer_to_manifest] Failed to provide config digest. Usage: cat | update_config <digest> <size> [<type>]"
    assert_value "${size}" "[EEE] [append_layer_to_manifest] Failed to provide size. Usage: cat | update_config <digest> <size> [<type>]"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    cat | \
        jq '.layers += [{"mediaType": $type, "size": $size | tonumber, "digest": $digest}]' \
            --arg type "${type}" \
            --arg digest "${digest}" \
            --arg size "${size}"
}

function append_layer_to_config() {
    local digest=$1
    local command=$2

    assert_pipeline_input "[EEE] [append_layer_to_config] Failed to provide pipeline input. Usage: cat | append_layer_to_config <digest> <command>"
    assert_value "${digest}" "[EEE] [append_layer_to_config] Failed to provide config digest. Usage: cat | append_layer_to_config <digest> <command>"
    assert_value "${command}" "[EEE] [append_layer_to_config] Failed to provide command. Usage: cat | append_layer_to_config <digest> <command>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    cat | \
        jq '.history += [$command | fromjson]' \
            --arg command "${command}" | \
        jq '.rootfs.diff_ids += [$diff]' \
            --arg diff "${digest}"
}

function insert_layer_in_config() {
    local index=$1
    local digest=$2

    assert_pipeline_input "[EEE] [insert_layer_in_config] Failed to provide pipeline input. Usage: cat | insert_layer_in_config <index> <digest>"
    assert_value "${index}" "[EEE] [insert_layer_in_config] Failed to provide index. Usage: cat | insert_layer_in_config <index> <digest>"
    assert_value "${digest}" "[EEE] [insert_layer_in_config] Failed to provide config digest. Usage: cat | insert_layer_in_config <index> <digest>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    cat | \
        jq '.rootfs.diff_ids = .rootfs.diff_ids[0:($index | tonumber)] + [$digest] + .rootfs.diff_ids[($index | tonumber):]' \
            --arg index "${index}" \
            --arg digest "${digest}"
}

function insert_layer_in_manifest() {
    local index=$1
    local digest=$2
    local size=$3
    local type=${4:-${MEDIA_type_LAYER}}

    assert_pipeline_input "[EEE] [insert_layer_in_manifest] Failed to provide pipeline input. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${index}" "[EEE] [insert_layer_in_manifest] Failed to provide index. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${digest}" "[EEE] [insert_layer_in_manifest] Failed to provide layer digest. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${size}" "[EEE] [insert_layer_in_manifest] Failed to provide layer size. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    cat | \
        jq '.layers = .layers[0:($index | tonumber)] + [{"mediaType": $type, "size": $size | tonumber, "digest": $digest}] + .layers[($index | tonumber):]' \
            --arg index "${index}" \
            --arg type "${type}" \
            --arg size "${size}" \
            --arg digest "${digest}"
}

function replace_layer_in_config() {
    local index=$1
    local digest=$2

    assert_pipeline_input "[EEE] [replace_layer_in_config] Failed to provide pipeline input. Usage: cat | replace_layer_in_config <index> <digest>"
    assert_value "${index}" "[EEE] [replace_layer_in_config] Failed to provide index. Usage: cat | replace_layer_in_config <index> <digest>"
    assert_value "${digest}" "[EEE] [replace_layer_in_config] Failed to provide layer digest. Usage: cat | replace_layer_in_config <index> <digest>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    cat | \
        jq '.rootfs.diff_ids[$index | tonumber] = $digest' \
            --arg index "${index}" \
            --arg digest "${digest}"
}

function replace_layer_in_manifest() {
    local index=$1
    local digest=$2
    local size=$3
    local type=${4:-${MEDIA_type_LAYER}}

    assert_pipeline_input "[EEE] [replace_layer_in_manifest] Failed to provide pipeline input. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${index}" "[EEE] [replace_layer_in_manifest] Failed to provide index. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${digest}" "[EEE] [replace_layer_in_manifest] Failed to provide layer digest. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${size}" "[EEE] [replace_layer_in_manifest] Failed to provide layer size. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    cat | \
        jq '.layers[$index | tonumber] = {"mediaType": $type, "size": $size | tonumber, "digest": $digest}' \
            --arg index "${index}" \
            --arg type "${type}" \
            --arg size "${size}" \
            --arg digest "${digest}"
}

function get_layer_index_by_command() {
    local command=$1

    assert_pipeline_input "[EEE] [get_layer_index_by_command] Failed to provide pipeline input. Usage: cat | get_layer_index_by_command <command>"
    assert_value "${command}" "[EEE] [get_layer_index_by_command] Failed to provide command. Usage: cat | get_layer_index_by_command <command>"

    cat | \
        jq '.history | to_entries[] | select(.value.created_by | startswith($command)) | .key' \
            --arg command "${command}"
}

function count_empty_layers_before_index() {
    local index=$1

    assert_pipeline_input "[EEE] [count_empty_layers_before_index] Failed to provide pipeline input. Usage: cat | count_empty_layers_before_index <index>"
    assert_value "${index}" "[EEE] [count_empty_layers_before_index] Failed to provide layer index. Usage: cat | count_empty_layers_before_index <index>"

    cat | \
        jq '.history | to_entries | map(select(.key < $index)) | map(select(.value.empty_layer == true)) | length' \
            --arg index "${index}"
}

function get_layer_digest_by_index() {
    local index=$1

    assert_pipeline_input "[EEE] [get_layer_digest_by_index] Failed to provide pipeline input. Usage: cat | get_layer_digest_by_index <index>"
    assert_value "${index}" "[EEE] [get_layer_digest_by_index] Failed to provide layer index. Usage: cat | get_layer_digest_by_index <index>"

    cat | \
        jq '.layers[$index | tonumber].digest' \
            --raw-output \
            --arg index "${index}"
}