MEDIA_TYPE_MANIFEST_V1=application/vnd.docker.distribution.manifest.v1+json
MEDIA_TYPE_MANIFEST_V2=application/vnd.docker.distribution.manifest.v2+json
MEDIA_TYPE_MANIFEST_LIST=application/vnd.docker.distribution.manifest.list.v2+json
MEDIA_TYPE_CONFIG=application/vnd.docker.container.image.v1+json
MEDIA_TYPE_LAYER=application/vnd.docker.image.rootfs.diff.tar.gzip

function parse_image() {
    local image=$1

    assert_value "${image}" "[ERROR] Failed to provide image. Usage: parse_image <image>"

    local registry=$(echo -n "${image}" | cut -d'/' -f1)
    local repository=$(echo -n "${image}" | cut -d'/' -f2- | cut -d':' -f1)
    local tag=$(echo -n "${image}" | cut -d'/' -f2- | cut -d':' -f2)

    echo "registry=${registry} repository=${repository} tag=${tag}"
}

function get_manifest() {
    local registry=$1
    local repository=$2
    local tag=${3:-latest}

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: get_manifest <registry> <repository> [<tag>]"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: get_manifest <registry> <repository> [<tag>]"

    >&2 echo "[get_manifest] Getting manifest from registry ${registry} for repository ${repository} with tag ${tag}"

    curl "${registry}/v2/${repository}/manifests/${tag}" \
        --silent \
        --header "Accept: ${MEDIA_TYPE_MANIFEST_V2}"
}

function get_config_digest() {
    assert_pipeline_input "[EEE] [get_config_digest] Failed to provide pipeline input. Usage: cat | get_config_digest"

    cat | \
        jq --raw-output '.config.digest'
}

function get_config_by_digest() {
    local registry=$1
    local repository=$2
    local digest=$3

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: get_config_by_digest <registry> <repository> <digest>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: get_config_by_digest <registry> <repository> <digest>"
    assert_value "${digest}" "[ERROR] Failed to provide digest. Usage: get_config_by_digest <registry> <repository> <digest>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    curl "${registry}/v2/${repository}/blobs/${digest}" \
            --silent \
            --header "Accept: ${MEDIA_TYPE_CONFIG}"
}

function get_config() {
    local registry=$1
    local repository=$2
    local tag=${3:-latest}

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: get_config <registry> <repository> [<tag>]"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: get_config <registry> <repository> [<tag>]"

    get_manifest "${registry}" "${repository}" "${tag}" | \
        get_config_digest | \
        xargs -I{} \
            curl "http://${registry}/v2/${repository}/blobs/{}" \
                --silent \
                --header "Accept: ${MEDIA_TYPE_CONFIG}"
}

function check_digest() {
    local registry=$1
    local repository=$2
    local digest=$3

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: check_digest <registry> <repository> <digest>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: check_digest <registry> <repository> <digest>"
    assert_value "${digest}" "[ERROR] Failed to provide digest. Usage: check_digest <registry> <repository> <digest>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    >&2 echo "[check_digest] Checking digest ${digest} for repository ${repository}"

    if curl --silent --fail --request HEAD --head --output /dev/null "${registry}/v2/${repository}/blobs/${digest}"; then
        return 0
    else
        return 1
    fi
}

function assert_digest() {
    local registry=$1
    local repository=$2
    local digest=$3

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: assert_digest <registry> <repository> <digest>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: assert_digest <registry> <repository> <digest>"
    assert_value "${digest}" "[ERROR] Failed to provide digest. Usage: assert_digest <registry> <repository> <digest>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    >&2 echo "[assert_digest] Asserting digest ${digest} for repository ${repository}"

    if ! check_digest "${registry}" "${repository}" "${digest}"; then
        echo "[ERROR] Unable to find digest ${digest} for repository ${repository}"
        exit 1
    fi
}

function get_blob() {
    local registry=$1
    local repository=$2
    local digest=$3
    local type=${4:-${MEDIA_TYPE_LAYER}}

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: get_blob <registry> <repository> <digest> [<type>]"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: get_blob <registry> <repository> <digest> [<type>]"
    assert_value "${digest}" "[ERROR] Failed to provide digest. Usage: get_blob <registry> <repository> <digest> [<type>]"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    >&2 echo "[get_blob] Fetching blob with digest ${digest} for repository ${repository}"

    curl -sH "Accept: ${TYPE}" "${registry}/v2/${repository}/blobs/${digest}"
}

function upload_manifest() {
    local registry=$1
    local repository=$2
    local tag=${3:-latest}

    assert_pipeline_input "[EEE] [upload_manifest] Failed to provide pipeline input. Usage: cat | upload_manifest <registry> <repository> [<tag>]"
    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: cat | upload_manifest <registry> <repository> [<tag>]"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: cat | upload_manifest <registry> <repository> [<tag>]"

    local manifest=$(cat)

    >&2 echo "[upload_manifest] Checking config digest"
    assert_digest "${registry}" "${repository}" "$(echo "${manifest}" | jq --raw-output '.config.digest')"

    for digest in $(echo "${manifest}" | jq --raw-output '.layers[].digest'); do
        >&2 echo "[upload_manifest] Checking layer digest "${digest}
        assert_digest "${registry}" "${repository}" "${digest}"
    done

    >&2 echo "[upload_manifest] Doing upload"
    curl "${registry}/v2/${repository}/manifests/${tag}" \
        --silent \
        --fail \
        --request PUT \
        --header "Content-Type: ${MEDIA_TYPE_MANIFEST_V2}" \
        --data "${manifest}"            
}

function get_upload_uuid() {
    local registry=$1
    local repository=$2

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: get_upload_uuid <registry> <repository>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: get_upload_uuid <registry> <repository>"

    >&2 echo "[get_upload_uuid] repository=${repository}"
    curl "${registry}/v2/${repository}/blobs/uploads/" \
            --silent \
            --fail \
            --request POST \
            --head | \
        grep "^Location:" | \
        cut -d' ' -f2- | \
        tr -d '\r'
}

function upload_config() {
    local registry=$1
    local repository=$2

    assert_pipeline_input "[EEE] [upload_config] Failed to provide pipeline input. Usage: cat | upload_config <registry> <repository>"
    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: cat | upload_config <registry> <repository>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: cat | upload_config <registry> <repository>"

    >&2 echo "[upload_config] repository=${repository}"

    local config="$(cat)"
    local config_digest="sha256:$(echo -n "${config}" | sha256sum | cut -d' ' -f1)"

    >&2 echo "[upload_config] Check existence of digest ${config_digest} in repository ${repository}"
    if check_digest "${registry}" "${repository}" "${config_digest}"; then
        >&2 echo "[upload_config] Digest already exists"
        return
    fi
    >&2 echo "[upload_config] Does not exist yet"

    local upload_url="$(get_upload_uuid "${registry}" "${repository}")&digest=${config_digest}"
    >&2 echo "[upload_config] URL is <${upload_url}>"

    >&2 echo "[upload_config] Upload config"
    curl "${upload_url}" \
        --fail \
        --request PUT \
        --header "Content-Type: ${MEDIA_TYPE_CONFIG}" \
        --data "${config}"
    >&2 echo "[upload_config] Done"
}

function upload_blob() {
    local registry=$1
    local repository=$2
    local layer=$3
    local type=$4

    >&2 echo "[upload_blob] Got $@"

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: upload_blob <registry> <repository> <file> <type>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: upload_blob <registry> <repository> <file> <type>"
    assert_value "${layer}" "[ERROR] Failed to provide layer. Usage: upload_blob <registry> <repository> <file> <type>"
    assert_value "${type}" "[ERROR] Failed to provide media type. Usage: upload_blob <registry> <repository> <file> <type>"

    >&2 echo "[upload_blob] repository=${repository}"

    blob_digest="sha256:$(sha256sum "${layer}" | cut -d' ' -f1)"

    >&2 echo "[upload_blob] Check existence of digest ${blob_digest} in repository ${repository}"
    if check_digest "${registry}" "${repository}" "${blob_digest}"; then
        >&2 echo "[upload_blob] Digest already exists"
        return
    fi
    >&2 echo "[upload_blob] Does not exist yet"

    local upload_url="$(get_upload_uuid "${registry}" "${repository}")&digest=${blob_digest}"
    >&2 echo "[upload_blob] URL is <${upload_url}>"

    >&2 echo "[upload_blob] Upload blob"
    curl "${upload_url}" \
        --fail \
        --request PUT \
        --header "Content-Type: ${type}" \
        --data-binary "@${layer}"
    >&2 echo "[upload_blob] Done"
}

function mount_digest() {
    local registry=$1
    local repository=$2
    local source=$3
    local digest=$4

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: mount_digest <registry> <repository> <tag> <digest>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: mount_digest <registry> <repository> <tag> <digest>"
    assert_value "${source}" "[ERROR] Failed to provide source tag. Usage: mount_digest <registry> <repository> <tag> <digest>"
    assert_value "${digest}" "[ERROR] Failed to provide blob digest. Usage: mount_digest <registry> <repository> <tag> <digest>"

    if test "${digest:0:7}" != "sha256:"; then
        digest="sha256:${digest}"
    fi

    >&2 echo "[mount_digest] START"

    if ! check_digest "${registry}" "${repository}" "${digest}"; then
        >&2 echo "[mount_digest] Mounting ${digest} in ${repository} from ${source}"

        curl "${registry}/v2/${repository}/blobs/uploads/?mount=${digest}&from=${source}" \
            --silent \
            --fail \
            --request POST
    fi
}

tag_remote() {
    local registry=$1
    local repository=$2
    local src=$3
    local dst=$4

    assert_value "${registry}" "[ERROR] Failed to provide registry. Usage: tag_remote <registry> <repository> <tag> <tag>"
    assert_value "${repository}" "[ERROR] Failed to provide repository. Usage: tag_remote <registry> <repository> <tag> <tag>"
    assert_value "${src}" "[ERROR] Failed to provide source tag. Usage: tag_remote <registry> <repository> <tag> <tag>"
    assert_value "${dst}" "[ERROR] Failed to provide destination tag. Usage: tag_remote <registry> <repository> <tag> <tag>"

    get_manifest "${registry}" "${repository}" "${src}" | \
        upload_manifest "${registry}" "${repository}" "${dst}"
}