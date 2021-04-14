MEDIA_TYPE_MANIFEST_V1=application/vnd.docker.distribution.manifest.v1+json
MEDIA_TYPE_MANIFEST_V2=application/vnd.docker.distribution.manifest.v2+json
MEDIA_TYPE_MANIFEST_LIST=application/vnd.docker.distribution.manifest.list.v2+json
MEDIA_TYPE_CONFIG=application/vnd.docker.container.image.v1+json
MEDIA_TYPE_LAYER=application/vnd.docker.image.rootfs.diff.tar.gzip

function get_manifest() {
    REPOSITORY=$1
    TAG=$2
    : "${TAG:=latest}"
    #echo "[get_manifest] Getting manifest from registry ${REGISTRY} for repository ${REPOSITORY} with tag ${TAG}"

    curl "http://${REGISTRY}/v2/${REPOSITORY}/manifests/${TAG}" \
        --silent \
        --header "Accept: ${MEDIA_TYPE_MANIFEST_V2}"
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
            --header "Accept: ${MEDIA_TYPE_CONFIG}"
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
                --header "Accept: ${MEDIA_TYPE_CONFIG}"
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
        --header "Content-Type: ${MEDIA_TYPE_MANIFEST_V2}" \
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

    >&2 echo "[upload_config] REPOSITORY=${REPOSITORY}"

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
        --header "Content-Type: ${MEDIA_TYPE_CONFIG}" \
        --data "${CONFIG}"
    >&2 echo "[upload_config] Done"
}

function upload_blob() {
    REPOSITORY=$1
    LAYER=$2
    TYPE=$3

    >&2 echo "[upload_blob] REPOSITORY=${REPOSITORY}"

    BLOB_DIGEST="sha256:$(sha256sum "${LAYER}" | cut -d' ' -f1)"

    >&2 echo "[upload_blob] Check existence of digest ${BLOB_DIGEST} in repository ${REPOSITORY}"
    if check_digest "${REPOSITORY}" "${BLOB_DIGEST}"; then
        >&2 echo "[upload_blob] Digest already exists"
        return
    fi
    >&2 echo "[upload_blob] Does not exist yet"

    UPLOAD_URL="$(get_upload_uuid "${REPOSITORY}")&digest=${BLOB_DIGEST}"
    >&2 echo "[upload_blob] URL is <${UPLOAD_URL}>"

    >&2 echo "[upload_blob] Upload blob"
    curl "${UPLOAD_URL}" \
        --fail \
        --request PUT \
        --header "Content-Type: ${TYPE}" \
        --data-binary "@${LAYER}"
    >&2 echo "[upload_blob] Done"
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