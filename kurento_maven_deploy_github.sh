#!/usr/bin/env bash



# Shell setup
# ===========

BASEPATH="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"  # Absolute canonical path
# shellcheck source=bash.conf.sh
source "$BASEPATH/bash.conf.sh" || exit 1

log "==================== BEGIN ===================="

# Check dependencies.
command -v jq >/dev/null || {
    log "ERROR: 'jq' is not installed; please install it"
    exit 1
}

# Trace all commands.
set -o xtrace



# Parse call arguments
# ====================

#/ Arguments:
#/
#/   All: Command to run.
#/      Mandatory.

MVN_COMMAND=("$@")
[[ -z "${MVN_COMMAND:+x}" ]] && {
    log "ERROR: Missing argument(s): Maven command to run"
    exit 1
}



# Helper functions
# ================

# Requires $GITHUB_TOKEN with `read:packages` and `delete:packages` scopes.

function delete_github_version {
    local GROUPID; GROUPID="$(mvn --batch-mode --quiet help:evaluate -Dexpression=project.groupId -DforceStdout)"
    local ARTIFACTID; ARTIFACTID="$(mvn --batch-mode --quiet help:evaluate -Dexpression=project.artifactId -DforceStdout)"
    local PROJECT_NAME="${GROUPID}.${ARTIFACTID}"

    local PROJECT_VERSION; PROJECT_VERSION="$(mvn --batch-mode --quiet help:evaluate -Dexpression=project.version -DforceStdout)"

    log "INFO: Reading all versions of '${PROJECT_NAME}' from GitHub."
    local API_VERSIONS_JSON; API_VERSIONS_JSON="$(
        curl -sS \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/orgs/kurento/packages/maven/$PROJECT_NAME/versions"
    )"

    local API_VERSION_ID; API_VERSION_ID="$(echo "$API_VERSIONS_JSON" | jq ".[] | select(.name==\"$PROJECT_VERSION\")? | .id")"
    [[ -n "$API_VERSION_ID" ]] || {
        log "WARNING: Version '${PROJECT_NAME}:${PROJECT_VERSION}' not found in GitHub. Nothing to delete."
        return
    }

    curl -sS \
        -X DELETE \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/kurento/packages/maven/$PROJECT_NAME/versions/$API_VERSION_ID"

    log "INFO: Successfully deleted version '${PROJECT_NAME}:${PROJECT_VERSION}' from GitHub."
}



# Deploy to GitHub
# ================

# Prepare a base command that doesn't include the "deploy" goal.
# This assumes that $MVN_COMMAND is a command like `mvn clean package deploy`,
# so omitting the last component would run through the compilation phase.
MVN_COMMAND_BASE=("${MVN_COMMAND[@]}")
unset 'MVN_COMMAND_BASE[-1]' # Drop the last item.

# Install packages into the local cache.
# We'll be deleting versions from the remote repository, so all dependencies
# must be already available locally when Maven runs.
"${MVN_COMMAND_BASE[@]}" install

# For each submodule, go into its path and delete the current GitHub version.
# shellcheck disable=SC2207
MVN_DIRS=( $("${MVN_COMMAND_BASE[@]}" --quiet exec:exec -Dexec.executable=pwd) ) || {
    log "ERROR: Command failed: mvn exec pwd"
    exit 1
}
for MVN_DIR in "${MVN_DIRS[@]}"; do
    pushd "$MVN_DIR"
    delete_github_version
    popd
done

# And now, finally, deploy the package (and submodules, if any).
"${MVN_COMMAND[@]}"



log "==================== END ===================="