function assert_value {
    VALUE=$1
    MESSAGE=$2

    if test -z "${VALUE}"; then
        echo "${MESSAGE}"
        exit 1
    fi
}