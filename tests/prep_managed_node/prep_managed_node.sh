#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test parameters:
# REPO_NAME
#   Name of the role repository to test.
#
# GITHUB_ORG
#   Optional: GitHub org to fetch test repository from. Default: linux-system-roles. Can be set to a fork for test purposes.
GITHUB_ORG="${GITHUB_ORG:-linux-system-roles}"
# REQUIRED_VARS
#   Env variables required by this test
REQUIRED_VARS=("REPO_NAME")
# PYTHON_VERSION
#   Python version to install ansible-core with (EL 8, 9, 10 only).

tmt_tree_provision=${TMT_TREE%/*}/provision

rlJournalStart
    rlPhaseStartSetup
        rlRun "rlImport library"
        for required_var in "${REQUIRED_VARS[@]}"; do
            if [ -z "${!required_var}" ]; then
                rlDie "This required variable is unset: $required_var "
            fi
        done
        rolesCS8InstallPython
        rolesDistributeSSHKeys "$tmt_tree_provision"
        rolesEnableHA
        rolesDisableNFV
        rolesGenerateTestDisks
    rlPhaseEnd
rlJournalEnd