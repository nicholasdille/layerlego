function mount_config_blob() {
    REGISTRY=$1
    REPOSITORY=$2
    SOURCE=$3

    assert_pipeline_input "[EEE] [mount_config_blob] Failed to provide pipeline input. Usage: cat | mount_config_blob <registry> <repository> <repository>"
    assert_value "${REGISTRY}" "[EEE] [mount_config_blob] Failed to provide registry. Usage: cat | mount_config_blob <registry> <repository> <repository>"
    assert_value "${REPOSITORY}" "[EEE] [mount_config_blob] Failed to provide repository. Usage: cat | mount_config_blob <registry> <repository> <repository>"
    assert_value "${SOURCE}" "[EEE] [mount_config_blob] Failed to provide source repository. Usage: cat | mount_config_blob <registry> <repository> <repository>"

    >&2 echo "[mount_config_blob] Mount config from ${SOURCE} to ${REPOSITORY}"

    cat | \
        jq --raw-output '.config.digest' | \
        while read -r DIGEST; do
            >&2 echo "[mount_blobs] Mount config digest ${DIGEST}"
            mount_digest "${REGISTRY}" join base "${DIGEST}"
        done
}

function mount_layer_blobs() {
    REGISTRY=$1
    REPOSITORY=$2
    SOURCE=$3

    assert_pipeline_input "[EEE] [mount_layer_blobs] Failed to provide pipeline input. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"
    assert_value "${REGISTRY}" "[EEE] [mount_layer_blobs] Failed to provide registry. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"
    assert_value "${REPOSITORY}" "[EEE] [mount_layer_blobs] Failed to provide repository. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"
    assert_value "${SOURCE}" "[EEE] [mount_layer_blobs] Failed to provide source repository. Usage: cat | mount_layer_blobs <registry> <repository> <repository>"

    >&2 echo "[mount_layer_blobs] Mount layer blobs from repository ${SOURCE} to repository ${REPOSITORY}"

    cat | \
        jq --raw-output '.layers[].digest' | \
        while read -r DIGEST; do
            >&2 echo "[mount_layer_blobs] Mount layer digest ${DIGEST}"
            mount_digest "${REGISTRY}" "${REPOSITORY}" "${SOURCE}" "${DIGEST}"
        done
}

function mount_blobs() {
    REGISTRY=$1
    REPOSITORY=$2
    SOURCE=$3
    TAG=${4:-latest}

    assert_value "${REGISTRY}" "[EEE] [mount_blobs] Failed to provide registry. Usage: mount_blobs <registry> <repository> <repository> [<tag>]"
    assert_value "${REPOSITORY}" "[EEE] [mount_blobs] Failed to provide repository. Usage: mount_blobs <registry> <repository> <repository> [<tag>]"
    assert_value "${SOURCE}" "[EEE] [mount_blobs] Failed to provide source repository. Usage: mount_blobs <registry> <repository> <repository> [<tag>]"

    >&2 echo "[mount_blobs] Mount config and all layers from ${SOURCE}:${TAG} to ${REPOSITORY}"

    MANIFEST="$(get_manifest "${REGISTRY}" "${SOURCE}" "${TAG}")"

    echo -n "${MANIFEST}" | \
        mount_config_blob "${REGISTRY}" "${REPOSITORY}" "${SOURCE}"
    
    echo -n "${MANIFEST}" | \
        mount_layers_blobs "${REGISTRY}" "${REPOSITORY}" "${SOURCE}"
}

function get_blob_metadata() {
    >&2 echo "[get_blob_metadata]"
    BLOB="$(cat)"

    assert_pipeline_input "[EEE] [get_blob_metadata] Failed to provide pipeline input. Usage: cat | get_blob_metadata"

    CONFIG_DIGEST="sha256:$(echo -n "${BLOB}" | sha256sum | cut -d' ' -f1)"
    CONFIG_SIZE="$(echo -n "${BLOB}" | wc -c)"

    echo "${CONFIG_DIGEST} ${CONFIG_SIZE}"
}

function update_config() {
    DIGEST=$1
    SIZE=$2

    assert_pipeline_input "[EEE] [update_config] Failed to provide pipeline input. Usage: cat | update_config <digest> <size>"
    assert_value "${DIGEST}" "[EEE] [update_config] Failed to provide config digest. Usage: cat | update_config <digest> <size>"
    assert_value "${SIZE}" "[EEE] [update_config] Failed to provide size. Usage: cat | update_config <digest> <size>"

    if test "${DIGEST:0:7}" != "sha256:"; then
        DIGEST="sha256:${DIGEST}"
    fi

    >&2 echo "[update_config] DIGEST=${DIGEST} SIZE=${SIZE}"

    cat | \
        jq '.config.digest = $digest | .config.size = ($size | tonumber)' \
            --arg digest "${DIGEST}" \
            --arg size "${SIZE}"
}

function append_layer_to_manifest() {
    DIGEST=$1
    SIZE=$2
    TYPE=${3:-${MEDIA_TYPE_LAYER}}

    assert_pipeline_input "[EEE] [append_layer_to_manifest] Failed to provide pipeline input. Usage: cat | update_config <digest> <size> [<type>]"
    assert_value "${DIGEST}" "[EEE] [append_layer_to_manifest] Failed to provide config digest. Usage: cat | update_config <digest> <size> [<type>]"
    assert_value "${SIZE}" "[EEE] [append_layer_to_manifest] Failed to provide size. Usage: cat | update_config <digest> <size> [<type>]"

    if test "${DIGEST:0:7}" != "sha256:"; then
        DIGEST="sha256:${DIGEST}"
    fi

    cat | \
        jq '.layers += [{"mediaType": $type, "size": $size | tonumber, "digest": $digest}]' \
            --arg type "${TYPE}" \
            --arg digest "${DIGEST}" \
            --arg size "${SIZE}"
}

function append_layer_to_config() {
    DIGEST=$1
    COMMAND=$2

    assert_pipeline_input "[EEE] [append_layer_to_config] Failed to provide pipeline input. Usage: cat | append_layer_to_config <digest> <command>"
    assert_value "${DIGEST}" "[EEE] [append_layer_to_config] Failed to provide config digest. Usage: cat | append_layer_to_config <digest> <command>"
    assert_value "${COMMAND}" "[EEE] [append_layer_to_config] Failed to provide command. Usage: cat | append_layer_to_config <digest> <command>"

    cat | \
        jq '.history += [$command | fromjson]' \
            --arg command "${COMMAND}" | \
        jq '.rootfs.diff_ids += [$diff]' \
            --arg diff "${DIGEST}"
}

function insert_layer_in_config() {
    INDEX=$1
    DIGEST=$2

    assert_pipeline_input "[EEE] [insert_layer_in_config] Failed to provide pipeline input. Usage: cat | insert_layer_in_config <index> <digest>"
    assert_value "${INDEX}" "[EEE] [insert_layer_in_config] Failed to provide index. Usage: cat | insert_layer_in_config <index> <digest>"
    assert_value "${DIGEST}" "[EEE] [insert_layer_in_config] Failed to provide config digest. Usage: cat | insert_layer_in_config <index> <digest>"

    if test "${DIGEST:0:7}" != "sha256:"; then
        DIGEST="sha256:${DIGEST}"
    fi

    cat | \
        jq '.rootfs.diff_ids = .rootfs.diff_ids[0:($index | tonumber)] + [$digest] + .rootfs.diff_ids[($index | tonumber):]' \
            --arg index "${INDEX}" \
            --arg digest "${DIGEST}"
}

function insert_layer_in_manifest() {
    INDEX=$1
    DIGEST=$2
    SIZE=$3
    TYPE=${4:-${MEDIA_TYPE_LAYER}}

    assert_pipeline_input "[EEE] [insert_layer_in_manifest] Failed to provide pipeline input. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${INDEX}" "[EEE] [insert_layer_in_manifest] Failed to provide index. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${DIGEST}" "[EEE] [insert_layer_in_manifest] Failed to provide layer digest. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${SIZE}" "[EEE] [insert_layer_in_manifest] Failed to provide layer size. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"

    if test "${DIGEST:0:7}" != "sha256:"; then
        DIGEST="sha256:${DIGEST}"
    fi

    cat | \
        jq '.layers = .layers[0:($index | tonumber)] + [{"mediaType": $type, "size": $size | tonumber, "digest": $digest}] + .layers[($index | tonumber):]' \
            --arg index "${INDEX}" \
            --arg type "${TYPE}" \
            --arg size "${SIZE}" \
            --arg digest "${DIGEST}"
}

function replace_layer_in_config() {
    INDEX=$1
    DIGEST=$2

    assert_pipeline_input "[EEE] [replace_layer_in_config] Failed to provide pipeline input. Usage: cat | replace_layer_in_config <index> <digest>"
    assert_value "${INDEX}" "[EEE] [replace_layer_in_config] Failed to provide index. Usage: cat | replace_layer_in_config <index> <digest>"
    assert_value "${DIGEST}" "[EEE] [replace_layer_in_config] Failed to provide layer digest. Usage: cat | replace_layer_in_config <index> <digest>"

    if test "${DIGEST:0:7}" != "sha256:"; then
        DIGEST="sha256:${DIGEST}"
    fi

    cat | \
        jq '.rootfs.diff_ids[$index | tonumber] = $digest' \
            --arg index "${INDEX}" \
            --arg digest "${DIGEST}"
}

function replace_layer_in_manifest() {
    INDEX=$1
    DIGEST=$2
    SIZE=$3
    TYPE=${4:-${MEDIA_TYPE_LAYER}}

    assert_pipeline_input "[EEE] [replace_layer_in_manifest] Failed to provide pipeline input. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${INDEX}" "[EEE] [replace_layer_in_manifest] Failed to provide index. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${DIGEST}" "[EEE] [replace_layer_in_manifest] Failed to provide layer digest. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"
    assert_value "${SIZE}" "[EEE] [replace_layer_in_manifest] Failed to provide layer size. Usage: cat | insert_layer_in_manifest <index> <digest> <size> [<type>]"

    if test "${DIGEST:0:7}" != "sha256:"; then
        DIGEST="sha256:${DIGEST}"
    fi

    cat | \
        jq '.layers[$index | tonumber] = {"mediaType": $type, "size": $size | tonumber, "digest": $digest}' \
            --arg index "${INDEX}" \
            --arg type "${TYPE}" \
            --arg size "${SIZE}" \
            --arg digest "${DIGEST}"
}

function get_layer_index_by_command() {
    COMMAND=$1

    assert_pipeline_input "[EEE] [get_layer_index_by_command] Failed to provide pipeline input. Usage: cat | get_layer_index_by_command <command>"
    assert_value "${COMMAND}" "[EEE] [get_layer_index_by_command] Failed to provide command. Usage: cat | get_layer_index_by_command <command>"

    cat | \
        jq '.history | to_entries[] | select(.value.created_by | startswith($command)) | .key' \
            --arg command "${COMMAND}"
}

function count_empty_layers_before_index() {
    INDEX=$1

    assert_pipeline_input "[EEE] [count_empty_layers_before_index] Failed to provide pipeline input. Usage: cat | count_empty_layers_before_index <index>"
    assert_value "${INDEX}" "[EEE] [count_empty_layers_before_index] Failed to provide layer index. Usage: cat | count_empty_layers_before_index <index>"

    cat | \
        jq '.history | to_entries | map(select(.key < $index)) | map(select(.value.empty_layer == true)) | length' \
            --arg index "${INDEX}"
}

function get_layer_digest_by_index() {
    INDEX=$1

    assert_pipeline_input "[EEE] [get_layer_digest_by_index] Failed to provide pipeline input. Usage: cat | get_layer_digest_by_index <index>"
    assert_value "${INDEX}" "[EEE] [get_layer_digest_by_index] Failed to provide layer index. Usage: cat | get_layer_digest_by_index <index>"

    cat | \
        jq '.layers[$index | tonumber].digest' \
            --raw-output \
            --arg index "${INDEX}"
}