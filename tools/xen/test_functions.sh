#!/bin/bash

. functions

# Mocking out filesystem functions
function _dir_exists {
    for directory in $(cat $LIST_OF_DIRECTORIES)
    do
        if [ "$directory" = "$1" ]
        then
            return 0
        fi
    done
    return 1
}

function _make_temp_file {
    echo "tempfile"
}

function _make_temp_dir {
    echo "tempdir"
}

function _download {
    echo "$1 downloaded to $2" >> $LIST_OF_ACTIONS
}

function _unzip {
    echo "random rubbish from unzip"
    echo "$1 unzipped to $2" >> $LIST_OF_ACTIONS
}

function _remove {
    echo "$1 removed" >> $LIST_OF_ACTIONS
}

function _recursive_mkdir {
    echo "$1" >> $LIST_OF_DIRECTORIES
}

# Setup
function before_each_test {
    LIST_OF_DIRECTORIES=$(mktemp)
    truncate -s 0 $LIST_OF_DIRECTORIES

    LIST_OF_ACTIONS=$(mktemp)
    truncate -s 0 $LIST_OF_ACTIONS
}

# Teardown
function after_each_test {
    rm -f $LIST_OF_DIRECTORIES
    rm -f $LIST_OF_ACTIONS
}

# Helpers
function given_directory_exists {
    echo "$1" >> $LIST_OF_DIRECTORIES
}

function assert_directory_exists {
    grep "$1" $LIST_OF_DIRECTORIES
}

function assert_previous_command_failed {
    [ "$?" != "0" ] || exit 1
}

# Tests
function test_plugin_directory_on_xenserver {
    given_directory_exists "/etc/xapi.d/plugins/"

    PLUGDIR=$(xapi_plugin_location)

    [ "/etc/xapi.d/plugins/" = "$PLUGDIR" ]
}

function test_plugin_directory_on_xcp {
    given_directory_exists "/usr/lib/xcp/plugins/"

    PLUGDIR=$(xapi_plugin_location)

    [ "/usr/lib/xcp/plugins/" = "$PLUGDIR" ]
}

function test_no_plugin_directory_found {
    set +e

    SOME=$(xapi_plugin_location)

    assert_previous_command_failed
}

function test_zip_snapshot_location {
    diff \
    <(zip_snapshot_location "https://github.com/openstack/nova.git" "master") \
    <(echo "https://github.com/openstack/nova/zipball/master")
}

function test_create_directory_for_kernels {
    create_directory_for_kernels

    assert_directory_exists "/boot/guest"
}

function test_extract_remote_zipball {
    local RESULT=$(extract_remote_zipball "someurl")

    diff <(cat $LIST_OF_ACTIONS) - << EOF
someurl downloaded to tempfile
tempfile unzipped to tempdir
tempfile removed
EOF

    [ "$RESULT" = "tempdir" ]
}

function test_find_nova_plugins {
    local tmpdir=$(mktemp -d)

    mkdir -p "$tmpdir/blah/blah/u/xapi.d/plugins"

    [ "$tmpdir/blah/blah/u/xapi.d/plugins" = $(find_xapi_plugins_dir $tmpdir) ]

    rm -rf $tmpdir
}

# Test runner
[ "$1" = "" ] && {
    grep -e "^function *test_" $0 | cut -d" " -f2
}

[ "$1" = "run_tests" ] && {
    for testname in $($0)
    do
        echo "$testname"
        before_each_test
        (
            set -eux
            $testname
        )
        if [ "$?" != "0" ]
        then
            echo "FAIL"
            exit 1
        else
            echo "PASS"
        fi

        after_each_test
    done
}
