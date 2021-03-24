function get_manifest() {
    REPOSITORY=$1
    TAG=$2
    : "${TAG:=latest}"

    curl "http://${REGISTRY}/v2/${REPOSITORY}/manifests/${TAG}" \
        --silent \
        --header "Accept: application/vnd.docker.distribution.manifest.v2+json"
}

function get_config_digest() {
    cat | \
        jq --raw-output '.config.digest'
}

function get_config_by_digest() {
    REPOSITORY=$1
    DIGEST=$2

    curl "http://${REGISTRY}/v2/${REPOSITORY}/blobs/${DIGEST}" \
            --silent \
            --header "Accept: application/vnd.docker.container.image.v1+json"
}

function get_config() {
    REPOSITORY=$1
    TAG=$2
    : "${TAG:=latest}"

    get_manifest "${REPOSITORY}" "${TAG}" | \
        get_config_digest | \
        xargs -I{} \
            curl "http://${REGISTRY}/v2/${REPOSITORY}/blobs/{}" \
                --silent \
                --header "Accept: application/vnd.docker.container.image.v1+json"
}

function check_digest() {
    REPOSITORY=$1
    DIGEST=$2

    #echo "[check_digest] Checking digest ${DIGEST} for repository ${REPOSITORY}"
    if curl --silent --fail --request HEAD --head --output /dev/null "http://${REGISTRY}/v2/${REPOSITORY}/blobs/${DIGEST}"; then
        return 0
    else
        return 1
    fi
}

function assert_digest() {
    REPOSITORY=$1
    DIGEST=$2

    #echo "[assert_digest] Asserting digest ${DIGEST} for repository ${REPOSITORY}"
    if ! check_digest "${REPOSITORY}" "${DIGEST}"; then
        echo "[ERROR] Unable to find digest ${DIGEST} for repository ${REPOSITORY}"
        exit 1
    fi
}

function upload_manifest() {
    REPOSITORY=$1
    TAG=$2
    : "${TAG:=latest}"

    MANIFEST=$(cat)

    echo "[upload_manifest] Checking config digest"
    assert_digest "${REPOSITORY}" "$(echo "${MANIFEST}" | jq --raw-output '.config.digest')"

    for DIGEST in $(echo "${MANIFEST}" | jq --raw-output '.layers[].digest'); do
        echo "[upload_manifest] Checking layer digest "${DIGEST}
        assert_digest "${REPOSITORY}" "${DIGEST}"
    done

    echo "[upload_manifest] Doing upload"
    curl "http://${REGISTRY}/v2/${REPOSITORY}/manifests/${TAG}" \
        --silent \
        --fail \
        --request PUT \
        --header "Content-Type: application/vnd.docker.distribution.manifest.v2+json" \
        --data "${MANIFEST}"            
}

function get_upload_uuid() {
    REPOSITORY=$1

    >&2 echo "[get_upload_uuid] REPOSITORY=${REPOSITORY}"
    curl "${REGISTRY}/v2/${REPOSITORY}/blobs/uploads/" \
            --silent \
            --fail \
            --request POST \
            --head | \
        grep "^Location:" | \
        cut -d' ' -f2- | \
        tr -d '\r'
}

function upload_config() {
    REPOSITORY=$1
    TAG=$2
    : "${TAG:=latest}"

    >&2 echo "[upload_config] REPOSITORY=${REPOSITORY} TAG=${TAG}"

    CONFIG="$(cat)"
    CONFIG_DIGEST="sha256:$(echo -n "${CONFIG}" | sha256sum | cut -d' ' -f1)"

    >&2 echo "[upload_config] Check existence of digest ${CONFIG_DIGEST} in repository ${REPOSITORY}"
    if check_digest "${REPOSITORY}" "${CONFIG_DIGEST}"; then
        >&2 echo "[upload_config] Digest already exists"
        return
    fi
    >&2 echo "[upload_config] Does not exist yet"

    UPLOAD_URL="$(get_upload_uuid "${REPOSITORY}")&digest=${CONFIG_DIGEST}"
    >&2 echo "[upload_config] URL is <${UPLOAD_URL}>"

    >&2 echo "[upload_config] Upload config"
    curl "${UPLOAD_URL}" \
        --fail \
        --request PUT \
        --header "Content-Type: application/vnd.docker.container.image.v1+json" \
        --data "${CONFIG}"
    >&2 echo "[upload_config] Done"
}

function mount_digest() {
    REPOSITORY=$1
    SOURCE=$2
    DIGEST=$3

    if ! check_digest "${REPOSITORY}" "${DIGEST}"; then
        curl "http://${REGISTRY}/v2/${REPOSITORY}/blobs/uploads/?mount=${DIGEST}&from=${SOURCE}" \
            --silent \
            --fail \
            --request POST
    fi
}