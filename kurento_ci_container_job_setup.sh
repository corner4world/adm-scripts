#!/usr/bin/env bash

echo "##################### EXECUTE: kurento_ci_container_job_setup #####################"
trap cleanup EXIT

# Enable command traces for debugging
set -o xtrace

# Starts a Docker container, prepares CI environment, and runs commands

#/
#/ Arguments:
#/
#/   All: Commands to run.
#/      Optional.
#/      Default: $BUILD_COMMAND
#/

# CONTAINER_IMAGE
#   Optional
#   Name of container image to use
#   Default: kurento/dev-integration:jdk-8-node-0.12
#
# KURENTO_PROJECT
#   Optional
#   Kurento project to build
#   DEFAULT: current directory name
#
# KURENTO_PUBLIC_PROJECT
#   Optional
#   "Yes" if KURENTO_PROJECT is public, "no" otherwise
#   Default: "no"
#
# CHECKOUT
#   Optional
#   Specify if this script must checkout projects before test running
#   DEFAULT: false
#
# FORCE_RELEASE
#   Optional
#   On external modules is used to force a release
#   DEFAULT: undefined
#
# HTTP_CERT
#   Certificate required to upload artifacts to http server
#
# GNUPG_KEY
#   Private GNUPG key used to sign kurento artifacts
#
# GIT_KEY
#   SSH key required by git repository
#
# PROJECT_DIR path
#    Optional
#    Directory within workspace where test code is located.
#    DEFAULT: none
#
# START_KMS_CONTAINER [ true | false ]
#    Optional
#    Specifies if a KMS container must be started and linked to the
#    maven container. Hostname "kms" will be used.
#    DEFAULT: false
#

cleanup () {
    echo "[kurento_ci_container_job_setup] Clean up on exit"

    # Stop detached containers, if any

    # KMS
    if [[ -n "$KMS_CONTAINER_ID" ]]; then
        mkdir -p "$WORKSPACE/report-files"
        local REPORT_FILE="$WORKSPACE/report-files/external-kms.log"
        docker logs "$KMS_CONTAINER_ID" >"$REPORT_FILE"
        zip "${REPORT_FILE}.zip" "$REPORT_FILE"
        docker stop "$KMS_CONTAINER_ID"
        docker rm -v "$KMS_CONTAINER_ID"
    fi
}

# Constants
CONTAINER_WORKSPACE=/opt/kurento
CONTAINER_GIT_KEY=/opt/git_id_rsa
CONTAINER_HTTP_CERT=/opt/http.crt
CONTAINER_HTTP_KEY=/opt/http.key
CONTAINER_MAVEN_LOCAL_REPOSITORY=/root/.m2
CONTAINER_MAVEN_SETTINGS=/opt/kurento-settings.xml
CONTAINER_TEST_CONFIG_JSON=/opt/scenario.conf.json
CONTAINER_ADM_SCRIPTS=/opt/adm-scripts
CONTAINER_GIT_CONFIG=/root/.gitconfig
CONTAINER_GNUPG_KEY=/opt/gnupg_key
CONTAINER_NPM_CONFIG=/root/.npmrc
CONTAINER_TEST_FILES=/opt/test-files

# Verify mandatory arguments
RUN_COMMANDS=("$@")
[ -z "${RUN_COMMANDS:+x}" ] && {
    echo "[kurento_ci_container_job_setup] WARNING: Missing argument(s): Commands to run"
    # Transition period from BUILD_COMMAND value to RUN_COMMANDS array
    [ -z "${BUILD_COMMAND:+x}" ] && {
        echo "[kurento_ci_container_job_setup] ERROR: Variable is empty: BUILD_COMMAND"
        exit 1
    }
    RUN_COMMANDS=("$BUILD_COMMAND")
}

# Verify mandatory parameters
[ -z "$CONTAINER_IMAGE" ] && CONTAINER_IMAGE="kurento/dev-integration:jdk-8-node-0.12"
[ -z "$KURENTO_PROJECT" ] && KURENTO_PROJECT=$(echo $GIT_URL | cut -d"/" -f2 | cut -d"." -f 1)
[ -z "$KURENTO_PUBLIC_PROJECT" ] && KURENTO_PUBLIC_PROJECT="no"
[ -z "$BASE_NAME" ] && BASE_NAME=$KURENTO_PROJECT

# Set default Parameters
[ -z "$WORKSPACE" ] && WORKSPACE="."
[ -z "$KMS_AUTOSTART" ] && KMS_AUTOSTART="test"
[ -z "$KMS_SCOPE" ] && KMS_SCOPE="docker"
[ -z "$KURENTO_SSH_USER" ] && KURENTO_SSH_USER="jenkinskurento"
[ -z "$SELENIUM_SCOPE" ] && SELENIUM_SCOPE=docker
[ -z "$MAVEN_GOALS" ] && MAVEN_GOALS="verify"
[ -z "$MAVEN_LOCAL_REPOSITORY" ] && MAVEN_LOCAL_REPOSITORY="$WORKSPACE/m2"
[ -z "$RECORD_TEST" ] && RECORD_TEST="false"

# Create temporary folders
[ -d $WORKSPACE/tmp ] || mkdir -p $WORKSPACE/tmp
[ -d $MAVEN_LOCAL_REPOSITORY ] || mkdir -p $MAVEN_LOCAL_REPOSITORY
[ -d /var/lib/jenkins/test-files ] || mkdir -p /var/lib/jenkins/test-files

# Find path to Git config file, if any
JENKINS_GIT_CONFIG=""
if [[ -n "$GIT_CONFIG" ]]; then
    # GIT_CONFIG defined by the job, possibly with a Jenkins managed file
    # `git` also uses GIT_CONFIG to override default search paths
    JENKINS_GIT_CONFIG="$GIT_CONFIG"
elif [[ -f "$HOME/.gitconfig" ]]; then
    # No config provided by the job; use defaults set by Jenkins Git plugin
    JENKINS_GIT_CONFIG="$HOME/.gitconfig"
elif [[ -f "$HOME/.config/git/config" ]]; then
    # No config provided by the job; use defaults set by Jenkins Git plugin
    # (alternative path, see git-config docs)
    JENKINS_GIT_CONFIG="$HOME/.config/git/config"
fi

# Update test files
docker run --pull always \
  --rm \
  --name $BUILD_TAG-TEST-FILES-$(date +"%s") \
  -v $KURENTO_SCRIPTS_HOME:$CONTAINER_ADM_SCRIPTS \
  -v /var/lib/jenkins/test-files:$CONTAINER_TEST_FILES \
  -w $CONTAINER_TEST_FILES \
  kurento/svn-client:1.0.0 \
  /opt/adm-scripts/kurento_update_test_files.sh || {
    echo "[kurento_ci_container_job_setup] ERROR: Command failed: docker run kurento_update_test_files"
    exit $?
  }
#     kurento/svn-client:1.0.0 svn checkout http://files.kurento.org/svn/kurento . || exit

# Start a KMS container if the job requires it
if [[ "$START_KMS_CONTAINER" == "true" ]]; then
    KMS_CONTAINER_ID="$(docker run --pull always -d --name "$BUILD_TAG-KMS-$(date +"%s")" \
        kurento/kurento-media-server:dev)" \
    || {
        echo "[kurento_ci_container_job_setup] ERROR: Command failed: docker run"
        exit $?
    }
    KMS_AUTOSTART=false
fi

# Set maven options
MAVEN_OPTIONS+=" -Dtest.kms.docker.image.forcepulling=false"
MAVEN_OPTIONS+=" -Djava.awt.headless=true"
MAVEN_OPTIONS+=" -Dtest.kms.autostart=$KMS_AUTOSTART"
MAVEN_OPTIONS+=" -Dtest.kms.scope=$KMS_SCOPE"
MAVEN_OPTIONS+=" -Dproject.path=$CONTAINER_WORKSPACE$([ -n "$MAVEN_MODULE" ] && echo "/$MAVEN_MODULE")"
MAVEN_OPTIONS+=" -Dtest.workspace=$CONTAINER_WORKSPACE/tmp"
MAVEN_OPTIONS+=" -Dtest.workspace.host=$WORKSPACE/tmp"
MAVEN_OPTIONS+=" -Dtest.files=$CONTAINER_TEST_FILES"
MAVEN_OPTIONS+=" -Dtest.selenium.scope=$SELENIUM_SCOPE"
MAVEN_OPTIONS+=" -Dtest.selenium.record=$RECORD_TEST"

[ -n "$TEST_GROUP" ] && MAVEN_OPTIONS+=" -Dgroups=$TEST_GROUP"
[ -n "$TEST_NAME" ] && MAVEN_OPTIONS+=" -Dtest=$TEST_NAME"
[ -n "$BOWER_RELEASE_URL" ] && MAVEN_OPTIONS+=" -Dbower.release.url=$BOWER_RELEASE_URL"
[ -n "$KMS_CONTAINER_ID" ] && MAVEN_OPTIONS+=" -Dkms.ws.uri=ws://kms:8888/kurento"
[ -z "$KMS_CONTAINER_ID" -a -n "$KMS_WS_URI" ] && MAVEN_OPTIONS+=" -Dkms.ws.uri=$KMS_WS_URI"
[ -n "$SCENARIO_TEST_CONFIG_JSON" ] && MAVEN_OPTIONS+=" -Dtest.config.file=$CONTAINER_TEST_CONFIG_JSON"

if [[ -z "$TEST_CONTAINER_NAME" ]]; then
  TEST_CONTAINER_NAME="${BUILD_TAG}-JOB_SETUP-$(date '+%s')"
fi

# Create main container
docker run --pull always \
  --name "$TEST_CONTAINER_NAME" \
  $([ "$DETACHED" = "true" ] && echo "-d" || echo "--rm") \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/jenkins/test-files:$CONTAINER_TEST_FILES \
  -v $KURENTO_SCRIPTS_HOME:$CONTAINER_ADM_SCRIPTS \
  -v $WORKSPACE$([ -n "$PROJECT_DIR" ] && echo "/$PROJECT_DIR"):$CONTAINER_WORKSPACE \
  $([ -f "$MAVEN_SETTINGS" ] && echo "-v $MAVEN_SETTINGS:$CONTAINER_MAVEN_SETTINGS") \
  -v $MAVEN_LOCAL_REPOSITORY:$CONTAINER_MAVEN_LOCAL_REPOSITORY \
  $([ -f "$HTTP_CERT" ] && echo "-v $HTTP_CERT:$CONTAINER_HTTP_CERT") \
  $([ -f "$HTTP_KEY" ] && echo "-v $HTTP_KEY:$CONTAINER_HTTP_KEY") \
  $([ -f "$GIT_KEY" ] && echo "-v $GIT_KEY:$CONTAINER_GIT_KEY" ) \
  $([ -n "$JENKINS_GIT_CONFIG" ] && echo "-v $JENKINS_GIT_CONFIG:$CONTAINER_GIT_CONFIG") \
  $([ -f "$GNUPG_KEY" ] && echo "-v $GNUPG_KEY:$CONTAINER_GNUPG_KEY") \
  $([ -f "$NPM_CONFIG" ] && echo "-v $NPM_CONFIG:$CONTAINER_NPM_CONFIG") \
  $([ -f "$SCENARIO_TEST_CONFIG_JSON" ] && echo "-v $SCENARIO_TEST_CONFIG_JSON:$CONTAINER_TEST_CONFIG_JSON") \
  -e "ASSEMBLY_FILE=$ASSEMBLY_FILE" \
  -e "BASE_NAME=$BASE_NAME" \
  $([ "${BUILD_ID}x" != "x" ] && echo "-e BUILD_ID=$BUILD_ID") \
  $([ "${BUILD_TAG}x" != "x" ] && echo "-e BUILD_TAG=$BUILD_TAG") \
  $([ "${BUILD_URL}x" != "x" ] && echo "-e BUILD_URL=$BUILD_URL") \
  $([ "${CLUSTER_REFSPEC}x" != "x" ] && echo "-e CLUSTER_REFSPEC=$CLUSTER_REFSPEC") \
  -e "KURENTO_SSH_USER=$KURENTO_SSH_USER" \
  -e "CREATE_TAG=$CREATE_TAG" \
  -e "CUSTOM_PRE_COMMAND=$CUSTOM_PRE_COMMAND" \
  -e "EXTRA_PACKAGES=$EXTRA_PACKAGES" \
  -e "FILES=$FILES" \
  -e "FORCE_RELEASE=$FORCE_RELEASE" \
  -e "GERRIT_REFSPEC=$GERRIT_REFSPEC" \
  -e "GIT_KEY=$CONTAINER_GIT_KEY" \
  -e "GITHUB_TOKEN=$GITHUB_TOKEN" \
  -e "GNUPG_KEY=$CONTAINER_GNUPG_KEY" \
  -e "GNUPG_KEY_ID=$GNUPG_KEY_ID" \
  -e "HTTP_CERT=$CONTAINER_HTTP_CERT" \
  -e "HTTP_KEY=$CONTAINER_HTTP_KEY" \
  $([ "${JENKINS_URL}x" != "x" ] && echo "-e JENKINS_URL=$JENKINS_URL") \
  $([[ -n "${JOB_GIT_NAME:-}" ]] && echo "-e JOB_GIT_NAME=$JOB_GIT_NAME") \
  $([ "${JOB_NAME}x" != "x" ] && echo "-e JOB_NAME=$JOB_NAME") \
  $([ "${JOB_URL}x" != "x" ] && echo "-e JOB_URL=$JOB_URL") \
  -e "KURENTO_GIT_REPOSITORY=$KURENTO_GIT_REPOSITORY" \
  -e "KURENTO_PROJECT=$KURENTO_PROJECT" \
  -e "KURENTO_PUBLIC_PROJECT=$KURENTO_PUBLIC_PROJECT" \
  -e "MAVEN_GOALS=$MAVEN_GOALS" \
  -e "MAVEN_MODULE=$MAVEN_MODULE" \
  -e "MAVEN_OPTIONS=$MAVEN_OPTIONS" \
  -e "MAVEN_SETTINGS=$CONTAINER_MAVEN_SETTINGS" \
  -e "MAVEN_SHELL_SCRIPT=$MAVEN_SHELL_SCRIPT" \
  -e "BOWER_REPO_NAME=$BOWER_REPO_NAME" \
  -e "FILES=$FILES" \
  -e "BUILDS_HOST=$BUILDS_HOST" \
  -e "S3_BUCKET_NAME=$S3_BUCKET_NAME" \
  $([ "${AWS_ACCESS_KEY_ID}x" != "x" ] && echo "-e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID") \
  $([ "${AWS_SECRET_ACCESS_KEY}x" != "x" ] && echo "-e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY") \
  -e "S3_HOSTNAME=$S3_HOSTNAME" \
  -e "UBUNTU_PRIV_S3_ACCESS_KEY_ID=$UBUNTU_PRIV_S3_ACCESS_KEY_ID" \
  -e "UBUNTU_PRIV_S3_SECRET_ACCESS_KEY_ID=$UBUNTU_PRIV_S3_SECRET_ACCESS_KEY_ID" \
  -e "WORKSPACE=$CONTAINER_WORKSPACE" \
  $([ -n "$KMS_CONTAINER_ID" ] && echo "--link $KMS_CONTAINER_ID:kms") \
  -u "root" \
  -w "$CONTAINER_WORKSPACE" \
  --entrypoint /bin/bash \
  $CONTAINER_IMAGE \
  "${CONTAINER_ADM_SCRIPTS}/kurento_ci_container_entrypoint.sh" "${RUN_COMMANDS[@]}"

status=$?

# Change worspace ownership to avoid permission errors caused by docker usage of root
[ -n "$WORKSPACE" ] && sudo chown -R $(whoami) $WORKSPACE

exit ${status:-0}
