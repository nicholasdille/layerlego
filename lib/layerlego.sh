function mount_config_blob() {
    REPOSITORY=$1
    SOURCE=$2

    cat | \
        jq --raw-output '.config.digest' | \
        while read -r DIGEST; do
            #echo "[mount_blobs] Mount config digest ${DIGEST}"
            mount_digest join base "${DIGEST}"
        done
}

function mount_layer_blobs() {
    REPOSITORY=$1
    SOURCE=$2

    cat | \
        jq --raw-output '.layers[].digest' | \
        while read -r DIGEST; do
            #echo "[mount_layers] Mount layer digest ${DIGEST}"
            mount_digest "${REPOSITORY}" "${SOURCE}" "${DIGEST}"
        done
}

function mount_blobs() {
    REPOSITORY=$1
    SOURCE=$2
    TAG=$3
    : "${TAG:=latest}"

    MANIFEST="$(get_manifest "${SOURCE}" "${TAG}")"

    echo -n "${MANIFEST}" | \
        mount_config_blob "${REPOSITORY}" "${SOURCE}"
    
    echo -n "${MANIFEST}" | \
        mount_layers_blobs "${REPOSITORY}" "${SOURCE}"
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

    >&2 echo "[update_config] DIGEST=${DIGEST} SIZE=${SIZE}"
    cat | \
        jq '.config.digest = $digest | .config.size = ($size | tonumber)' \
            --arg digest "${DIGEST}" \
            --arg size "${SIZE}"
}