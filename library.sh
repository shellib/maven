#!/bin/bash

source $(grab github.com/shellib/cli)

DEFAULT_NEXUS_URL="https://oss.sonatype.org"
DEFAULT_NEXUS_STAGING_PLUGIN_VERSION="1.6.8"
DEFAULT_NEXUS_SERVER_ID="oss-sonatype-staging"

REPO_ANNOUNCEMENT_PREFIX="OpenedStagingProfile"


#
# Opens a staging repository on nexus.
open_staging_repository() {
    local staging_profile_id=$1
    local nexus_url=${2:-$DEFAULT_NEXUS_URL}
    local nexus_server_id=${3:-$NEXUS_SERVER_ID}
    local maven_opts=$4
    local maven_args="org.sonatype.plugins:nexus-staging-maven-plugin:${NEXUS_STAGING_PLUGIN_VERSION}:rc-open -DnexusUrl=${nexus_url} -DserverId=${nexus_server_id} -DstagingProfileId=${staging_profile_id} -DopenedRepositoryMessageFormat='$REPO_ANNOUNCEMENT_PREFIX:%s' $maven_opts"
    #Call maven and just grab the last line that contains $REPO_ANNOUNCEMENT_PREFIX discard the line that displays the whole command and get the string that is between `:` and `'`.
    mvn $maven_args | grep -v maven | grep $REPO_ANNOUNCEMENT_PREFIX | awk -F ":" '{print $2}' | awk -F "'" '{print $1}'
}

#
# Performs an action on the staging repository
# Supported actions (close, release, drop)
with_staging_repository() {
    local action=$1
    local repo_id=$2
    local nexus_url=${3:-$DEFAULT_NEXUS_URL}
    local nexus_server_id=${4:-$NEXUS_SERVER_ID}
    local maven_opts=$5
    local maven_args="org.sonatype.plugins:nexus-staging-maven-plugin:${NEXUS_STAGING_PLUGIN_VERSION}:rc-${action} -DnexusUrl=${nexus_url} -DserverId=${nexus_server_id} -DstagingRepositoryId=$repo_id $maven_opts"
    mvn $maven_args > /dev/null
}

#
# Find the staging repository id.
# This is useful in case where the staging repo has been implicitly created by the maven-release-plugin.
find_staging_repo_id() {
    local maven_opts=$1
    local staging_repo_prefix=`find_staging_repo_prefix`
    local maven_args="org.sonatype.plugins:nexus-staging-maven-plugin:${NEXUS_STAGING_PLUGIN_VERSION}:rc-list -DnexusUrl=${nexus_url} -DserverId=${nexus_server_id} $maven_opts"

    mvn $maven_args | grep ${staging_repo_prefix} | head -n 1 | awk -F " " '{print $2}'
    }
#
# Closes a staging repository on nexus.
close_staging_repository() {
    with_staging_repository "close" $*
}

#
# Releases a staging repository on nexus.
release_staging_repository() {
    with_staging_repository "release" $*
}

#
# Drops a staging repository on nexus.
drop_staging_repository() {
    with_staging_repository "drop" $*
}

#
# Performs the actual release
maven_release() {
    local staging_profile_id=$(readopt --staging-profile-id $*)
    local nexus_server_id=$(or $(readopt --nexus-server-id $*) $DEFAULT_NEXUS_SERVER_ID)
    local nexus_url=$(or $(readopt --nexus-url $*) $DEFAULT_NEXUS_URL)

    local dry_run=$(hasflag --dry-run $*)
    local release_snapshots=$(hasflag --release-snapshots $*)
    local release_version=$(readopt --release-version $*)
    local dev_version=$(readopt --dev-version $*)
    local maven_opts=""

    #Validation
    if [ -z "${release_snapshots}" ]; then
        if [ -z "${release_version}" ]; then
            echo "Please specify --release-version"
            exit 1
        fi

        if [ -z "${dev_version}" ]; then
            echo "Please specify --dev-version"
            exit 1
        fi
    fi


    local profiles=$(readopt --profiles)
    if [ -n "${profiles}" ]; then
        maven_opts="$maven_opts -P${profiles}"
    else
        maven_opts="-Prelease"
    fi

    local settings_xml=$(readopt --settings-xml)
    if [ -n "${settings_xml}" ]; then
        maven_opts="$maven_opts -s $settings_xml"
    fi

    local repo_id=""

    if [ -n "$staging_profile_id" ]; then
        echo "Creating new staging repository..."
        repo_id=$(open_staging_repository "$staging_profile_id" "$nexus_url" "$nexus_server_id" "$maven_opts")
        echo "Opened staging repository: $repo_id"
        #There is no tag yet, so let's pass $NO_TAG instead.
        trap "do_cleanup \"$repo_id\" \"$NO_TAG\" \"$maven_opts\"" EXIT
        do_release "$release_snapshots" "$release_version" "$dev_version" "$maven_opts"
    else
        do_release "$release_snapshots" "$release_version" "$dev_version" "$maven_opts"
        #There is no tag yet, so let's pass $NO_TAG instead.
        trap "do_cleanup \"$repo_id\" \"$NO_TAG\" \"$maven_opts\"" EXIT
        repo_id=`find_staging_repo_id $maven_opts`
    fi


    if [ -z "${release_snapshots}" ]; then
        #Update the trap with the tag created.
        local tag=$(find_tag)
        trap "do_cleanup \"$repo_id\" \"$tag\" \"$maven_opts\"" EXIT
    fi

    echo "Closing staging repository: $repo_id"
    close_staging_repository "$repo_id" "$nexus_url" "$nexus_server_id" "$maven_opts"

    if [ -n "$dry_run" ]; then
        echo "This is a dry run ..."
        echo "Droping tag $tag"
        git tag -d $tag
        echo "Droping staging repository: $repo_id"
        drop_staging_repository "$repo_id" "$nexus_url" "$nexus_server_id" "$maven_opts"
    else
        echo "Releasing staging repository: $repo_id"
        trap "echo Done!" EXIT
        exit
        release_staging_repository "$repo_id"  "$nexus_url" "$nexus_server_id" "$maven_opts"
        git push origin master
        git push orign $tag
    fi
}

#
# Helper functions
do_release() {
    local release_snapshots=$1
    local release_version=$2
    local dev_version=$4
    local maven_opts=$4

    local maven_args=""

    if [ -n "${dev_version}" ]; then
        maven_opts="$maven_opts -DdevelopmentVersion=${dev_version}"
    else
        current_version=$(find_project_version)
        if [ -n "${current_version}" ]; then
        maven_opts="$maven_opts -DdevelopmentVersion=${current_version}"
        fi
    fi

    if [ -n "${release_snapshots}" ]; then
        maven_args="clean package deploy:deploy $maven_opts"
    else
        maven_args="-B release:clean release:prepare release:perform -DconnectionUrl=scm:git:file://`pwd`/.git -Dtag=$release_version $maven_opts"
    fi

    mvn $maven_args
}

do_cleanup() {
    echo "Cleaning up ..."
    local repo_id=$1
    local tag=$2
    local maven_opts=$3
    if [ "$NO_TAG" == "$tag" ]; then
        echo "No tag has been specified. Skipping!"
    else
        echo "Droping tag $tag"
        git tag -d $tag || echo "Failed to drop tag: tag."
    fi
    echo "Droping staging repository: $repo_id"
    drop_staging_repository "$repo_id" "$maven_opts"
}

find_tag() {
    local release_version=$1
    git tag -l | grep $release_version | tail -n 1
}

find_group_id() {
    mvn -q -Dexec.executable="echo" -Dexec.args='${project.groupId}' --non-recursive org.codehaus.mojo:exec-maven-plugin:1.3.1:exec 2>/dev/null
}

find_project_version() {
    mvn -q -Dexec.executable="echo" -Dexec.args='${project.version}' --non-recursive org.codehaus.mojo:exec-maven-plugin:1.3.1:exec 2>/dev/null
}

find_staging_repo_prefix() {
    find_group_id | sed "s/\.//g"
}

#Only run maven_release if script is not sourced.
if [ -n "$1" ]; then
    maven_release $*
fi
