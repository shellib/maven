#!/bin/bash

source $(grab github.com/shellib/cli)
source $(grab github.com/shellib/wait)

DEFAULT_NEXUS_URL="https://oss.sonatype.org"
DEFAULT_NEXUS_STAGING_PLUGIN_VERSION="1.6.8"
DEFAULT_NEXUS_SERVER_ID="oss-sonatype-staging"

DEFAULT_REPO_URL="http://repo1.maven.org/maven2"

REPO_ANNOUNCEMENT_PREFIX="OpenedStagingProfile"

usage::release() {
echo "Perform a maven release (via nexus).

Requirements:

The artifacts (usually if not always) need to be signed. Setting up gpg and configuring credentials is beyond the scope of this tool.
The same applies to managing credentials of the nexus server. So the following assumptions regarding the setup are made:

1. Target nexus server is configured in distribution management of the pom and the credentials are configured in the settings.xml (a matching server entry should exist in settings.xml).

     <server>
        <id>your_server_id</id> <!-- correlates with the distribution management server found in the pom -->
        <username>your_username</username>
        <password>your_password</password>
    </server>

2. gpg is available locally and the key is configured in settings.xml:

    <profile>
            <id>your_profile_here</id>
            <properties>
                    <gpg.command>/usr/local/bin/gpg</gpg.command>
                    <gpg.keyname>your_gpg_key_here </gpg.keyname>
                    <gpg.passphrase>your_key_passphrase_here</gpg.passphrase>
            </properties>
    </profile>

Options and Flags:
 --release-version                 The version to release (defaults to the next micro version).
 --dev-version                     The version to set after the release (defaults to majosr-minor-SNAPSHOT).
 --profiles                        Profiles to enable. Refers to maven profiles (works like mvn -P).
 --settings-xml                    Path to the settings.xml  (defaults to system default)

 --staging-profile-id              The nexus staging profile id (usually its safe to ignore).
 --nexus-server-id                 The nexus server id (defaults to the value set in distribution management section of the pom).
 --nexus-url                       The url to the nexus server  (defaults to https://oss.sonatype.org, should be based handled in the pom)

 --wait-for-sync-timeout           The amount of time to wait (in seconds) until artifacts have been synced (defaults to 0).
 --sync-repo-uri                   The uri of the repository that the artifacts will be synced (defaults to https://repo1.maven.org/maven2/).
"
}

#
# Performs the actual release
__release() {
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
            release_version=`next_release_version`
        fi

        if [ -z "${dev_version}" ]; then
            dev_version=`next_dev_version`
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
        trap "release_cleanup \"$repo_id\" \"$NO_TAG\" \"$maven_opts\"" EXIT
        prepare_and_perform "$release_snapshots" "$release_version" "$dev_version" "$maven_opts"
    else
        prepare_and_perform "$release_snapshots" "$release_version" "$dev_version" "$maven_opts"
        #There is no tag yet, so let's pass $NO_TAG instead.
        trap "release_cleanup \"$repo_id\" \"$NO_TAG\" \"$maven_opts\"" EXIT
        repo_id=`find_staging_repo_id $maven_opts`
    fi


    if [ -z "${release_snapshots}" ]; then
        #Update the trap with the tag created.
        local tag=$(find_tag)
        trap "release_cleanup \"$repo_id\" \"$tag\" \"$maven_opts\"" EXIT
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
        release_staging_repository "$repo_id"  "$nexus_url" "$nexus_server_id" "$maven_opts"
        git push origin master
        git push origin $tag
        exit
    fi
}

#
# Helper functions


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
# Check if maven release is available
is_release_available() {
    local groupId=$1
    local artifactId=$2
    local version=$3

    if [ -z "$groupId" ] || [ -z "$artifactId" ] || [ -z "$version" ]; then
        exit 1
    fi

    local repo_url=$(or $(readopt --repo-url $*) $DEFAULT_REPO_URL)
    local group_path=`echo $groupId | sed "s/\./\//g"`
    local artifact_url="$repo_url/$group_path/$artifactId/$version/"
    local status_code=`curl -o /dev/null -sw '%{http_code}' $artifact_url`
    if [ $status_code -eq 200 ]; then
        echo "true"
    fi
}

prepare_and_perform() {
    local release_snapshots=$1
    local release_version=$2
    local dev_version=$3
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
        echo "mvn $maven_args"
        mvn $maven_args
    else
        maven_args="-B release:clean release:prepare -DreleaseVersion=${release_version} -Dtag=$release_version -DpushChanges=false $maven_opts"
        echo "mvn $maven_args"
        mvn $maven_args

        maven_args="-B release:perform -DconnectionUrl=scm:git:file://`pwd`/.git -DreleaseVersion=${release_version} -Dtag=${release_version} $maven_opts" 
        echo "mvn $maven_args"
        mvn $maven_args
	git push --tags
    fi
}

release_cleanup() {
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

major_version() {
    echo $1 | cut -d "." -f1 | cut -d "-" -f1
}

minor_version() {
    echo $1 | cut -d "." -f2 | cut -d "-" -f1
}

micro_version() {
    echo $1 | cut -d "." -f3 | cut -d "-" -f1
}

micro_suffix() {
    echo $1 | cut -d "-" -f2
}

find_staging_repo_prefix() {
    find_group_id | sed "s/\.//g"
}

next_release_version() {
    local version=`find_project_version`
    local major=`major_version $version`
    local minor=`minor_version $version`
    local micro=`micro_version $version`
    local suffix=`micro_suffix $version`
    # if there is no micro version, we need to check the latest release.
    if [ -z "$micro" ]; then
        local latest=`find_latest_release $major $minor`
        local latest_micro=`micro_version $latest`
        echo "$major.$minor.$((latest_micro+1))"
    elif [ -z "$suffix" ] || [ "SNAPSHOT" == "$suffix" ]; then
       echo "$major.$minor.$micro"
    else
       echo "$major.$minor.$micro-$suffix"
    fi
}

next_dev_version() {
    local version=`find_project_version`
    local major=`major_version $version`
    local minor=`minor_version $version`
    local micro=`micro_version $version`
    local suffix=`micro_suffix $version`
    # if there is no micro version, we need to check the latest release.
    if [ -z "$micro" ]; then
        echo "$version"
    else
       echo "$major.$minor.$((micro+1))-$suffix"
    fi

}

find_latest_release() {
    local major=$1
    local minor=$2
    git tag -l | grep "^$major\\.$minor\\." | sort | tail -n 1
}
