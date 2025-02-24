#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test parameters:
# ANSIBLE_VER
#   ansible version to use for tests. E.g. "2.9" or "2.16".
#
# REPO_NAME
#   Name of the role repository to test.
REPO_NAME=mssql
#
# TEST_LOCAL_CHANGES
#   Optional: When true, tests from local changes. When false, test from a repository PR number (when PR_NUM is set) or main branch.
TEST_LOCAL_CHANGES="${TEST_LOCAL_CHANGES:-tests_configure_ha_cluster_external.yml tests_configure_ha_cluster_read_scale.yml}"
#
# PR_NUM
#   Optional: Number of PR to test. If empty, tests the default branch.
#
# SYSTEM_ROLES_ONLY_TESTS
#  Optional: Space separated names of test playbooks to test. E.g. "tests_imuxsock_files.yml tests_relp.yml"
#  If empty, tests all tests in tests/tests_*.yml
SYSTEM_ROLES_ONLY_TESTS="${SYSTEM_ROLES_ONLY_TESTS:-false}"
#
# SYSTEM_ROLES_EXCLUDE_TESTS
#   Optional: Space separated names of test playbooks to exclude from test.
#
# GITHUB_ORG
#   Optional: GitHub org to fetch test repository from. Default: linux-system-roles. Can be set to a fork for test purposes.
GITHUB_ORG="${GITHUB_ORG:-linux-system-roles}"
# LINUXSYSTEMROLES_SSH_KEY
#   Optional: When provided, test uploads artifacts to LINUXSYSTEMROLES_DOMAIN instead of uploading them with rlFileSubmit "$logfile".
#   A Single-line SSH key.
#   When provided, requires LINUXSYSTEMROLES_USER and LINUXSYSTEMROLES_DOMAIN.
# LINUXSYSTEMROLES_USER
#   Username used when uploading artifacts.
# LINUXSYSTEMROLES_DOMAIN: secondary01.fedoraproject.org
#   Domain where to upload artifacts.
# PYTHON_VERSION
#   Python version to install ansible-core with (EL 8, 9, 10 only).
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
# SKIP_TAGS
#   Ansible tags that must be skipped
SKIP_TAGS="--skip-tags tests::nvme,tests::infiniband"
# LSR_TFT_DEBUG
#   Print output of ansible playbooks to terminal in addition to printing it to logfile
if [ "$(echo "$SYSTEM_ROLES_ONLY_TESTS" | wc -w)" -eq 1 ]; then
    LSR_TFT_DEBUG=true
else
    LSR_TFT_DEBUG="${LSR_TFT_DEBUG:-false}"
fi
# ANSIBLE_GATHERING
#   Use this to set value for the ANSIBLE_GATHERING environmental variable for ansible-playbook.
#   Choices: implicit, explicit, smart
#   https://docs.ansible.com/ansible/latest/reference_appendices/config.html#default-gathering
ANSIBLE_GATHERING="${ANSIBLE_GATHERING:-implicit}"

# REQUIRED_VARS
#   Env variables required by this test
REQUIRED_VARS=("ANSIBLE_VER")
# LSR_ANSIBLE_VERBOSITY
#   Default is "-vv" - user can locally edit tft.yml in role to increase this for debugging

rlJournalStart
    rlPhaseStartSetup
        rlRun "rlImport library"
        lsrPrepTestVars
        for required_var in "${REQUIRED_VARS[@]}"; do
            if [ -z "${!required_var}" ]; then
                rlDie "This required variable is unset: $required_var "
            fi
        done
        lsrInstallAnsible
        lsrGetRoleDir "$REPO_NAME"
        # role_path is defined in lsrGetRoleDir
        # shellcheck disable=SC2154
        legacy_test_path="$role_path"/tests
        test_playbooks=$(lsrGetTests "$legacy_test_path")
        rlLogInfo "Test playbooks: $test_playbooks"
        for test_playbook in $test_playbooks; do
            lsrHandleVault "$test_playbook"
        done
        lsrSetAnsibleGathering "$ANSIBLE_GATHERING"
        lsrGetCollectionPath
        # role_path is defined in lsrGetRoleDir
        # shellcheck disable=SC2154
        lsrInstallDependencies "$role_path" "$collection_path"
        lsrEnableCallbackPlugins "$collection_path"
        lsrConvertToCollection "$role_path" "$collection_path" "$REPO_NAME"
        # tmt_tree_provision and guests_yml is defined in lsrPrepTestVars
        # shellcheck disable=SC2154
        inventory_external=$(lsrPrepareInventoryVars "$tmt_tree_provision" "$guests_yml")
        inventory_read_scale=$(lsrPrepareInventoryVars "$tmt_tree_provision" "$guests_yml")

        declare -A external_node_types
        external_node_types[managed-node1]=primary
        external_node_types[managed-node2]=synchronous
        # external_node_types is used below when calling lsrMssqlHaUpdateInventory
        # shellcheck disable=SC2034
        external_node_types[managed-node3]=witness
        declare -A read_scale_node_types
        read_scale_node_types[managed-node1]=primary
        read_scale_node_types[managed-node2]=synchronous
        # read_scale_node_types is used below when calling lsrMssqlHaUpdateInventory
        # shellcheck disable=SC2034
        read_scale_node_types[managed-node3]=asynchronous

        lsrMssqlHaUpdateInventory "$inventory_external" external_node_types
        lsrMssqlHaUpdateInventory "$inventory_read_scale" read_scale_node_types

        # Find the IP of the virtualip node that was shut down
        virtualip_name=$(sed --quiet --regexp-extended 's/^(virtualip.*):/\1/p' "$guests_yml")
        virtualip=$(lsrGetNodeIp "$guests_yml" "$virtualip_name")
        # Shut down virtualip if it's pingable
        if ping -c1 "$virtualip"; then
            rlRun "ssh -i $tmt_tree_provision/$virtualip_name/id_ecdsa root@$virtualip -oStrictHostKeyChecking=no shutdown"
        fi
        # Replace mssql_ha_virtual_ip with our virtualip value
        tests_path="$collection_path"/ansible_collections/fedora/linux_system_roles/tests/"$REPO_NAME"/
        test_playbooks=$(lsrGetTests "$tests_path")
        collection_role_path="$collection_path"/ansible_collections/fedora/linux_system_roles/roles/"$REPO_NAME"
        collection_vars_path="$collection_role_path"/vars
        sed -i "s/mssql_ha_virtual_ip: .*/mssql_ha_virtual_ip: $virtualip/g" "$tests_path"/tests_configure_ha_cluster_external.yml
        rlRun "grep '^ *mssql_ha_virtual_ip' $tests_path/tests_configure_ha_cluster_external.yml"
    rlPhaseEnd
    rlPhaseStartTest
        os_ver=$(sed --quiet "/managed-node1\:/,/^[^ ]/p" "$guests_yml" | sed --quiet --regexp-extended 's/^[ ]*VERSION\: (.*)/\1/p' | sed "s/'//g" | sed 's/ /_/g')
        vars_file_name=CentOS_$os_ver.yml
        # Set supported versions from vars files, first from RedHat.yml, then from OS's file
        for var_file in "$collection_vars_path"/RedHat.yml "$collection_vars_path"/"$vars_file_name"; do
            if [ -f "$var_file" ]; then
                supported_versions=$(sed --quiet "/__mssql_supported_versions\:/,/^[^ ]/p" "$var_file" | grep -o '[0-9]*')
            fi
        done
        for test_playbook in $test_playbooks; do
            test_playbook_basename=$(basename "$test_playbook")
            for mssql_version in $supported_versions; do
                # Replace mssql_version value to one of the supported versions
                sed -i "s/mssql_version.*$/mssql_version: $mssql_version/g" "$test_playbook"
                rlRun "grep '^ *mssql_version:' $test_playbook"
                # tmt_plan is assigned at lsrPrepTestVars
                # shellcheck disable=SC2154
                LOGFILE="${test_playbook_basename%.*}"-ANSIBLE-"$ANSIBLE_VER"-"$tmt_plan"-"$mssql_version"
                if [ "$test_playbook_basename" = "tests_configure_ha_cluster_external.yml" ]; then
                    lsrRunPlaybook "$test_playbook" "$inventory_external" "$SKIP_TAGS" "" "$LOGFILE" "${LSR_ANSIBLE_VERBOSITY:--vv}"
                elif [ "$test_playbook_basename" = "tests_configure_ha_cluster_read_scale.yml" ]; then
                    lsrRunPlaybook "$test_playbook" "$inventory_read_scale" "$SKIP_TAGS" "" "$LOGFILE" "${LSR_ANSIBLE_VERBOSITY:--vv}"
                fi
            done
        done
    rlPhaseEnd
rlJournalEnd

