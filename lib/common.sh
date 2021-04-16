function assert_value {
    VALUE=$1
    MESSAGE=$2

    if test -z "${VALUE}"; then
        echo "[EEE] [assert_value] No value was supplied. Usage: assert_value <value> <message>"
        exit 1
    fi
    if test -z "${MESSAGE}"; then
        echo "[EEE] [assert_value] No message was supplied. Usage: assert_value <value> <message>"
        exit 1
    fi

    if test -z "${VALUE}"; then
        echo "${MESSAGE}"
        exit 1
    fi
}

function assert_pipeline_input() {
    MESSAGE=$1

    if test -z "${MESSAGE}"; then
        echo "[EEE] [assert_pipe_input] No message was supplied. Usage: assert_value <value> <message>"
        exit 1
    fi

    if test -t 0; then
        echo "${MESSAGE}"
        exit 1
    fi
}