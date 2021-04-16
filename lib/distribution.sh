MEDIA_TYPE_MANIFEST_V1=application/vnd.docker.distribution.manifest.v1+json
MEDIA_TYPE_MANIFEST_V2=application/vnd.docker.distribution.manifest.v2+json
MEDIA_TYPE_MANIFEST_LIST=application/vnd.docker.distribution.manifest.list.v2+json
MEDIA_TYPE_CONFIG=application/vnd.docker.container.image.v1+json
MEDIA_TYPE_LAYER=application/vnd.docker.image.rootfs.diff.tar.gzip

function assert_value {
    VALUE=$1
    MESSAGE=$2

    if test -z "${VALUE}"; then
        echo "${MESSAGE}"
        exit 1
    fi
}

function get_manifest() {
    REGISTRY=$1
    REPOSITORY=$2
    TAG=${3:-latest}

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: get_manifest <registry> <repository> [<tag>]"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: get_manifest <registry> <repository> [<tag>]"

    >&2 echo "[get_manifest] Getting manifest from registry ${REGISTRY} for repository ${REPOSITORY} with tag ${TAG}"

    curl "${REGISTRY}/v2/${REPOSITORY}/manifests/${TAG}" \
        --silent \
        --header "Accept: ${MEDIA_TYPE_MANIFEST_V2}"
}

function get_config_digest() {
    cat | \
        jq --raw-output '.config.digest'
}

function get_config_by_digest() {
    REGISTRY=$1
    REPOSITORY=$2
    DIGEST=$3

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: get_config_by_digest <registry> <repository> <digest>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: get_config_by_digest <registry> <repository> <digest>"
    assert_value "${DIGEST}" "[ERROR] Failed to provide digest. Usage: get_config_by_digest <registry> <repository> <digest>"

    curl "${REGISTRY}/v2/${REPOSITORY}/blobs/${DIGEST}" \
            --silent \
            --header "Accept: ${MEDIA_TYPE_CONFIG}"
}

function get_config() {
    REGISTRY=$1
    REPOSITORY=$2
    TAG=${3:-latest}

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: get_config <registry> <repository> [<tag>]"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: get_config <registry> <repository> [<tag>]"

    get_manifest "${REGISTRY}" "${REPOSITORY}" "${TAG}" | \
        get_config_digest | \
        xargs -I{} \
            curl "http://${REGISTRY}/v2/${REPOSITORY}/blobs/{}" \
                --silent \
                --header "Accept: ${MEDIA_TYPE_CONFIG}"
}

function check_digest() {
    REGISTRY=$1
    REPOSITORY=$2
    DIGEST=$3

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: check_digest <registry> <repository> <digest>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: check_digest <registry> <repository> <digest>"
    assert_value "${DIGEST}" "[ERROR] Failed to provide digest. Usage: check_digest <registry> <repository> <digest>"

    >&2 echo "[check_digest] Checking digest ${DIGEST} for repository ${REPOSITORY}"

    if curl --silent --fail --request HEAD --head --output /dev/null "${REGISTRY}/v2/${REPOSITORY}/blobs/${DIGEST}"; then
        return 0
    else
        return 1
    fi
}

function assert_digest() {
    REGISTRY=$1
    REPOSITORY=$2
    DIGEST=$3

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: assert_digest <registry> <repository> <digest>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: assert_digest <registry> <repository> <digest>"
    assert_value "${DIGEST}" "[ERROR] Failed to provide digest. Usage: assert_digest <registry> <repository> <digest>"

    >&2 echo "[assert_digest] Asserting digest ${DIGEST} for repository ${REPOSITORY}"

    if ! check_digest "${REGISTRY}" "${REPOSITORY}" "${DIGEST}"; then
        echo "[ERROR] Unable to find digest ${DIGEST} for repository ${REPOSITORY}"
        exit 1
    fi
}

function upload_manifest() {
    REGISTRY=$1
    REPOSITORY=$2
    TAG=${3:-latest}

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: cat | upload_manifest <registry> <repository> [<tag>]"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: cat | upload_manifest <registry> <repository> [<tag>]"

    MANIFEST=$(cat)

    >&2 echo "[upload_manifest] Checking config digest"
    assert_digest "${REGISTRY}" "${REPOSITORY}" "$(echo "${MANIFEST}" | jq --raw-output '.config.digest')"

    for DIGEST in $(echo "${MANIFEST}" | jq --raw-output '.layers[].digest'); do
        >&2 echo "[upload_manifest] Checking layer digest "${DIGEST}
        assert_digest "${REGISTRY}" "${REPOSITORY}" "${DIGEST}"
    done

    >&2 echo "[upload_manifest] Doing upload"
    curl "${REGISTRY}/v2/${REPOSITORY}/manifests/${TAG}" \
        --silent \
        --fail \
        --request PUT \
        --header "Content-Type: ${MEDIA_TYPE_MANIFEST_V2}" \
        --data "${MANIFEST}"            
}

function get_upload_uuid() {
    REGISTRY=$1
    REPOSITORY=$2

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: get_upload_uuid <registry> <repository>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: get_upload_uuid <registry> <repository>"

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
    REGISTRY=$1
    REPOSITORY=$2

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: cat | upload_config <registry> <repository>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: cat | upload_config <registry> <repository>"

    >&2 echo "[upload_config] REPOSITORY=${REPOSITORY}"

    CONFIG="$(cat)"
    CONFIG_DIGEST="sha256:$(echo -n "${CONFIG}" | sha256sum | cut -d' ' -f1)"

    >&2 echo "[upload_config] Check existence of digest ${CONFIG_DIGEST} in repository ${REPOSITORY}"
    if check_digest "${REGISTRY}" "${REPOSITORY}" "${CONFIG_DIGEST}"; then
        >&2 echo "[upload_config] Digest already exists"
        return
    fi
    >&2 echo "[upload_config] Does not exist yet"

    UPLOAD_URL="$(get_upload_uuid "${REGISTRY}" "${REPOSITORY}")&digest=${CONFIG_DIGEST}"
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
    REGISTRY=$1
    REPOSITORY=$2
    LAYER=$3
    TYPE=$4

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: upload_blob <registry> <repository> <file> <type>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: upload_blob <registry> <repository> <file> <type>"
    assert_value "${LAYER}" "[ERROR] Failed to provide layer. Usage: upload_blob <registry> <repository> <file> <type>"
    assert_value "${TYPE}" "[ERROR] Failed to provide media type. Usage: upload_blob <registry> <repository> <file> <type>"

    >&2 echo "[upload_blob] REPOSITORY=${REPOSITORY}"

    BLOB_DIGEST="sha256:$(sha256sum "${LAYER}" | cut -d' ' -f1)"

    >&2 echo "[upload_blob] Check existence of digest ${BLOB_DIGEST} in repository ${REPOSITORY}"
    if check_digest "${REGISTRY}" "${REPOSITORY}" "${BLOB_DIGEST}"; then
        >&2 echo "[upload_blob] Digest already exists"
        return
    fi
    >&2 echo "[upload_blob] Does not exist yet"

    UPLOAD_URL="$(get_upload_uuid "${REGISTRY}" "${REPOSITORY}")&digest=${BLOB_DIGEST}"
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
    REGISTRY=$1
    REPOSITORY=$2
    SOURCE=$3
    DIGEST=$4

    assert_value "${REGISTRY}" "[ERROR] Failed to provide registry. Usage: mount_digest <registry> <repository> <tag> <digest>"
    assert_value "${REPOSITORY}" "[ERROR] Failed to provide repository. Usage: mount_digest <registry> <repository> <tag> <digest>"
    assert_value "${SOURCE}" "[ERROR] Failed to provide source tag. Usage: mount_digest <registry> <repository> <tag> <digest>"
    assert_value "${DIGEST}" "[ERROR] Failed to provide blob digest. Usage: mount_digest <registry> <repository> <tag> <digest>"

    >&2 echo "[mount_digest] START"

    if ! check_digest "${REGISTRY}" "${REPOSITORY}" "${DIGEST}"; then
        >&2 echo "[mount_digest] Mounting ${DIGEST} in ${REPOSITORY} from ${SOURCE}"

        curl "${REGISTRY}/v2/${REPOSITORY}/blobs/uploads/?mount=${DIGEST}&from=${SOURCE}" \
            --silent \
            --fail \
            --request POST
    fi
}