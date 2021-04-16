function mount_config_blob() {
    REGISTRY=$1
    REPOSITORY=$2
    SOURCE=$3

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

    >&2 echo "[mount_layer_blobs]"

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

    CONFIG_DIGEST="sha256:$(echo -n "${BLOB}" | sha256sum | cut -d' ' -f1)"
    CONFIG_SIZE="$(echo -n "${BLOB}" | wc -c)"

    echo "${CONFIG_DIGEST} ${CONFIG_SIZE}"
}

function update_config() {
    DIGEST=$1
    SIZE=$2

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
    TYPE=$3

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

    cat | \
        jq '.history += [$command | fromjson]' \
            --arg command "${COMMAND}" | \
        jq '.rootfs.diff_ids += [$diff]' \
            --arg diff "${DIGEST}"
}

function insert_layer_in_config() {
    INDEX=$1
    DIGEST=$2

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

    cat | \
        jq '.history | to_entries[] | select(.value.created_by | startswith($command)) | .key' \
            --arg command "${COMMAND}"
}

function count_empty_layers_before_index() {
    INDEX=$1

    cat | \
        jq '.history | to_entries | map(select(.key < $index)) | map(select(.value.empty_layer == true)) | length' \
            --arg index "${INDEX}"
}

function get_layer_digest_by_index() {
    INDEX=$1

    cat | \
        jq '.layers[$index | tonumber].digest' \
            --raw-output \
            --arg index "${INDEX}"
}