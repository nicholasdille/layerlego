#!/bin/bash

function assert_value {
    value=$1
    message=$2

    if test -z "${value}"; then
        echo "[EEE] [assert_value] No value was supplied. Usage: assert_value <value> <message>"
        exit 1
    fi
    if test -z "${message}"; then
        echo "[EEE] [assert_value] No message was supplied. Usage: assert_value <value> <message>"
        exit 1
    fi

    if test -z "${value}"; then
        echo "${message}"
        exit 1
    fi
}

function assert_pipeline_input() {
    message=$1

    if test -z "${message}"; then
        echo "[EEE] [assert_pipe_input] No message was supplied. Usage: assert_value <value> <message>"
        exit 1
    fi

    if test -t 0; then
        echo "${message}"
        exit 1
    fi
}