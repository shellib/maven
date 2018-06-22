#!/bin/bash

source ./library.sh 

# Test Cases
should_succeed() {
    result=`is_release_available io.fabric8 kubernetes-client 3.1.12`
    if [ "$result" != "true" ]; then
        echo "FAIL: Release for groupId: io.fabric8 artfactId: kubernetes-client version: 3.1.12 exist, but got negative response: $result!"
        exit 1
    fi
}


should_fail() {
    result=`is_release_available this artifact does not exist`
    if [ "$result" == "true" ]; then
        echo "FAIL: Release doesn't exist but got positive response: $result!"
        exit 1
    fi
}


should_succeed
should_fail
