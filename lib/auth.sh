#!/bin/bash

: "${DOCKER_CONFIG:=${HOME}/.docker}"

get_docker_auth() {
    local registry=${1:-https://index.docker.io/v1/}

    >&2 echo "[get_docker_auth] Using registry ${registry}"

    # shellcheck disable=SC2002
    cat "${DOCKER_CONFIG}/config.json" | \
        jq --raw-output --arg registry "${registry}" '.auths | to_entries[] | select(.key == $registry) | .value.auth' | \
        base64 -d
}

get_token_usage() {
    echo "Usage: $0 <registry> <repository> <access> <username> <password> [<insecure>]"
    echo
    echo "           <registry>    Hostname of the container registry, e.g. index.docker.io"
    echo "           <repository>  Path of the repository to access, e.g. library/alpine"
    echo "           <access>      Required access, e.g. pull or push,pull"
    echo "           <username>    Username to use for authentication. Can be empty for anonymous access"
    echo "           <password>    Password for supplied username"
    echo "           <insecure>    Non-empty parameter forces HTTP otherwise HTTPS is used"
}

get_token() {
    local registry=${1:-index.docker.io}
    local repository=$2
    local access=${3:-pull}
    local user=$4
    local password=$5
    local insecure=$6

    >&2 echo "[get_token] Got registry=${registry} repository=${repository} access=${access} user=${user} password=${password} insecure=${insecure}"

    if [[ "$#" -lt 5 || "$#" -gt 6 ]]; then
        get_token_usage
        return
    fi

    local schema=https
    if test -n "${insecure}"; then
        schema=http
    fi
    >&2 echo "[get_token] Using schema ${schema}."

    local temp_dir
    temp_dir=$(mktemp -d)
    >&2 echo "[get_token] Using temporary directory ${temp_dir}."

    local http_code
    http_code=$(
        curl "${schema}://${registry}/v2/" \
            --silent \
            --location \
            --write-out "%{http_code}" \
            --output "${temp_dir}/body.txt" \
            --dump-header "${temp_dir}/header.txt")
    >&2 echo "[get_token] Got HTTP response code ${http_code}."

    case $http_code in
        401)
            >&2 echo "[get_token] Authentication required"

            local www_authenticate
            # shellcheck disable=SC2002
            www_authenticate=$(
                cat "${temp_dir}/header.txt" | \
                    grep -iE "^Www-Authenticate: " | \
                    tr -d '\r'
            )
            >&2 echo "[get_token] Got www_authenticate ${www_authenticate}."

            if test -n "${www_authenticate}"; then
                local service_info
                service_info=$(echo "${www_authenticate}" | cut -d' ' -f3)
                #>&2 echo "[get_token] service_info=${service_info}."

                local index=1
                while true; do
                    #>&2 echo "[get_token] index=${index}."

                    local item
                    item=$(echo "${service_info}" | cut -d',' -f${index})
                    #>&2 echo "[get_token] item=${item}."
                    if test -z "${item}"; then
                        break
                    fi

                    local key
                    key=$(echo "${item}" | cut -d= -f1)
                    local value
                    value=$(echo "${item}" | cut -d= -f2 | tr -d '"')
                    declare "$key"="$value"

                    index=$(( index + 1))
                done

                # shellcheck disable=SC2154
                >&2 echo "[get_token] realm=${realm}, service=${service}."
            fi

            if test -z "${repository}"; then
                >&2 echo "[get_token] Repository name not provided"
                get_token_usage
                test -d "${temp_dir}" && rm -rf "${temp_dir}"
                return
            fi

            >&2 echo "[get_token] user=${user} password=${password}"
            local basic_auth=""
            if test -n "${user}" && test -z "${password}"; then
                >&2 echo "[get_token] User name provided but missing password"
                usage
                test -d "${temp_dir}" && rm -rf "${temp_dir}"
                return

            elif test -z "${user}"; then
                >&2 echo "[get_token] No authentication specified"

                local auth
                auth=$(get_docker_auth "${registry}")
                >&2 echo "[get_token] Got auth length=${#auth}"
                if test -n "${auth}"; then
                    >&2 echo "[get_token] Setting basic authentication from Docker credentials"
                    basic_auth="--user ${auth}"
                fi

            else
                >&2 echo "[get_token] Using basic authentication"
                basic_auth="--user ${user}:${password}"
            fi

            >&2 echo curl "${realm}" \
                --silent \
                --request GET \
                ${basic_auth} \
                --data-urlencode "service=${service}" \
                --data-urlencode "scope=repository:${repository}:${access}"
            local code
            code=$(
                curl "${realm}" \
                    --silent \
                    --request GET \
                    ${basic_auth} \
                    --data-urlencode "service=${service}" \
                    --data-urlencode "scope=repository:${repository}:${access}" \
                    --output "${temp_dir}/body.json" \
                    --write-out "%{http_code}"
            )
            >&2 echo "[get_token] Got HTTP response code ${code}."

            if test "${code}" -lt 300; then
                >&2 echo "[get_token] Successfully obtained token"

                local expiry_seconds
                # shellcheck disable=SC2002
                expiry_seconds=$(cat "${temp_dir}/body.json" | jq --raw-output '.expires_in')
                >&2 echo "Token expires in ${expiry_seconds} seconds"
                # shellcheck disable=SC2002
                cat "${temp_dir}/body.json" | jq --raw-output '.token'

            else
                >&2 echo "[get_token] Failed to obtain token"
                cat "${temp_dir}/body.json"
                test -d "${temp_dir}" && rm -rf "${temp_dir}"
                return
            fi
            ;;
    esac

    test -d "${temp_dir}" && rm -rf "${temp_dir}"
}