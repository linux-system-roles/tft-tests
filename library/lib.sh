#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Description: Library for system roles tests
#   Author: Sergei Petrosian <spetrosi@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   library-prefix = library
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

rolesInstallAnsible() {
    if rlIsRHELLike 7; then
        # Hardcode to the only supported version on EL 7
        ANSIBLE_VER=2.9
    fi
    if rlIsFedora || (rlIsRHELLike ">7" && [ "$ANSIBLE_VER" != "2.9" ]); then
        rlRun "dnf install python$PYTHON_VERSION-pip -y"
        rlRun "python$PYTHON_VERSION -m pip install ansible-core==$ANSIBLE_VER.*"
    elif rlIsRHELLike 8; then
        PYTHON_VERSION=3.9
        rlRun "dnf install python$PYTHON_VERSION -y"
        rlRun "python$PYTHON_VERSION -m pip install ansible==$ANSIBLE_VER.*"
    else
        # el7
        rlRun "yum install ansible-$ANSIBLE_VER.* -y"
    fi
}

rolesCloneRepo() {
    local role_path=$1
    if [ ! -d "$role_path" ]; then
        rlRun "git clone https://github.com/$GITHUB_ORG/$REPO_NAME.git $role_path"
    fi
    if [ -n "$PR_NUM" ]; then
        # git on EL7 doesn't support -C option
        pushd "$role_path" || exit
        rlRun "git fetch origin pull/$PR_NUM/head"
        rlRun "git checkout FETCH_HEAD"
        popd || exit
    fi
}

rolesGetTests() {
    local role_path=$1
    local test_playbooks_all test_playbooks
    tests_path="$role_path"/tests/
    test_playbooks_all=$(find "$tests_path" -maxdepth 1 -type f -name "tests_*.yml" -printf '%f\n')
    if [ -n "$SYSTEM_ROLES_ONLY_TESTS" ]; then
        for test_playbook in $test_playbooks_all; do
            if echo "$SYSTEM_ROLES_ONLY_TESTS" | grep -q "$test_playbook"; then
                test_playbooks="$test_playbooks $test_playbook"
            fi
        done
    else
        test_playbooks="$test_playbooks_all"
    fi
    if [ -n "$SYSTEM_ROLES_EXCLUDE_TESTS" ]; then
        test_playbooks_excludes=""
        for test_playbook in $test_playbooks; do
            if ! echo "$SYSTEM_ROLES_EXCLUDE_TESTS" | grep -q "$test_playbook"; then
                test_playbooks_excludes="$test_playbooks_excludes $test_playbook"
            fi
        done
        test_playbooks=$test_playbooks_excludes
    fi
    if [ -z "$test_playbooks" ]; then
        rlDie "No test playbooks found"
    fi
    echo "$test_playbooks"
}

# Handle Ansible Vault encrypted variables
rolesHandleVault() {
    local role_path=$1
    local playbook_file=$2
    local vault_pwd_file="$role_path/vault_pwd"
    local vault_variables_file="$role_path/vars/vault-variables.yml"
    local no_vault_file="$role_path/no-vault-variables.txt"
    local vault_play

    if [ -f "$vault_pwd_file" ] && [ -f "$vault_variables_file" ]; then
        if grep -q "^${playbook_file}\$" "$no_vault_file"; then
            rlLogInfo "Skipping vault variables because $3/$2 is in no-vault-variables.txt"
        else
            rlLogInfo "Including vault variables in $playbook_file"
            vault_play="- hosts: all
  gather_facts: false
  tasks:
    - name: Include vault variables
      include_vars:
        file: $vault_variables_file"
            rlRun "sed -i \"s|---||$vault_play\" $playbook_file"
        fi
    else
        rlLogInfo "Skipping vault variables because $vault_pwd_file and $vault_variables_file don't exist"
    fi
}

rolesInstallDependencies() {
    local coll_req_file="$1/meta/collection-requirements.yml"
    local coll_test_req_file="$1/tests/collection-requirements.yml"
    for req_file in $coll_req_file $coll_test_req_file; do
        if [ ! -f "$req_file" ]; then
            rlLogInfo "Skipping installing dependencies from $req_file, this file doesn't exist"
        else
            rlRun "ansible-galaxy collection install -p $2 -vv -r $req_file"
            rlRun "export ANSIBLE_COLLECTIONS_PATHS=$2"
            rlLogInfo "Dependencies were successfully installed"
        fi
    done
}

rolesEnableCallbackPlugins() {
    local collection_path=$1
    # Enable callback plugins for prettier ansible output
    callback_path=ansible_collections/ansible/posix/plugins/callback
    if [ ! -f "$collection_path"/"$callback_path"/debug.py ] || [ ! -f "$collection_path"/"$callback_path"/profile_tasks.py ]; then
        ansible_posix=$(TMPDIR=$TMT_TREE mktemp --directory)
        rlRun "ansible-galaxy collection install ansible.posix -p $ansible_posix -vv"
        if [ ! -d "$1"/"$callback_path"/ ]; then
            rlRun "mkdir -p $collection_path/$callback_path"
        fi
        rlRun "cp $ansible_posix/$callback_path/{debug.py,profile_tasks.py} $collection_path/$callback_path/"
        rlRun "rm -rf $ansible_posix"
    fi
    if ansible-config list | grep -q "name: ANSIBLE_CALLBACKS_ENABLED"; then
        rlRun "export ANSIBLE_CALLBACKS_ENABLED=profile_tasks"
    else
        rlRun "export ANSIBLE_CALLBACK_WHITELIST=profile_tasks"
    fi
    rlRun "export ANSIBLE_STDOUT_CALLBACK=debug"
}

rolesConvertToCollection() {
    local role_path=$1
    local collection_path=$2
    local collection_script_url=https://raw.githubusercontent.com/linux-system-roles/auto-maintenance/main
    local coll_namespace=fedora
    local coll_name=linux_system_roles
    local subrole_prefix=private_"$REPO_NAME"_subrole_
    rlRun "curl -L -o $TMT_TREE/lsr_role2collection.py $collection_script_url/lsr_role2collection.py"
    rlRun "curl -L -o $TMT_TREE/runtime.yml $collection_script_url/lsr_role2collection/runtime.yml"
    # Remove role that was installed as a dependencie
    rlRun "rm -rf $collection_path/ansible_collections/fedora/linux_system_roles/roles/$REPO_NAME"
    rlRun "python$PYTHON_VERSION -m pip install ruamel-yaml"
    # Remove symlinks in tests/roles
    if [ -d "$role_path"/tests/roles ]; then
        find "$role_path"/tests/roles -type l -exec rm {} \;
        if [ -d "$role_path"/tests/roles/linux-system-roles."$REPO_NAME" ]; then
            rlRun "rm -r $role_path/tests/roles/linux-system-roles.$REPO_NAME"
        fi
    fi
    rlRun "python$PYTHON_VERSION $TMT_TREE/lsr_role2collection.py \
--meta-runtime $TMT_TREE/runtime.yml \
--src-owner linux-system-roles \
--role $REPO_NAME \
--src-path $role_path \
--dest-path $collection_path \
--namespace $coll_namespace \
--collection $coll_name \
--subrole-prefix $subrole_prefix"
}

rolesPrepareInventoryVars() {
    local role_path=$1
    local tmt_tree_provision=$2
    local guests_yml=$3
    local inventory is_virtual  managed_nodes
    inventory="$role_path/inventory.yml"
    # TMT_TOPOLOGY_ variables are not available in tmt try.
    # Reading topology from guests.yml for compatibility with tmt try
    is_virtual=$(rolesIsVirtual "$tmt_tree_provision")
    managed_nodes=$(grep -P -o '^managed_node(\d+)?' "$guests_yml")
    rlRun "python$PYTHON_VERSION -m pip install yq -q"
    if [ ! -f "$inventory" ]; then
        echo "---
all:
  hosts:" > "$inventory"
    fi
    for managed_node in $managed_nodes; do
        ip_addr=$(yq ".$managed_node.\"primary-address\"" "$guests_yml")
        echo "    $managed_node:" >> "$inventory"
        echo "      ansible_host: $ip_addr" >> "$inventory"
        echo "      ansible_ssh_extra_args: \"-o StrictHostKeyChecking=no\"" >> "$inventory"
        if [ "$is_virtual" -eq 0 ]; then
            echo "      ansible_ssh_private_key_file: ${tmt_tree_provision}/control_node/id_ecdsa" >> "$inventory"
        fi
    done
    rlRun "echo $inventory"
}

rolesIsVirtual() {
    # Returns 0 if provisioned with "how: virtual"
    local tmt_tree_provision=$1
    grep -q 'how: virtual' "$tmt_tree_provision"/step.yaml
    echo $?
}

rolesUploadLogs() {
    local logfile=$1
    local guests_yml=$2
    local id_rsa_path pr_substr os artifact_dirname target_dir
    if [ -z "$LINUXSYSTEMROLES_SSH_KEY" ]; then
        rlFileSubmit "$logfile"
        return
    fi
    id_rsa_path="$role_path/id_rsa"
    echo "$LINUXSYSTEMROLES_SSH_KEY" | \
        sed -e 's|-----BEGIN OPENSSH PRIVATE KEY----- |-----BEGIN OPENSSH PRIVATE KEY-----\n|' \
        -e 's| -----END OPENSSH PRIVATE KEY-----|\n-----END OPENSSH PRIVATE KEY-----|' > "$id_rsa_path" # notsecret
    chmod 600 "$id_rsa_path"
    if [ -z "$ARTIFACTS_DIR" ]; then
        os=$(yq '.control_node.facts."os-release-content".CENTOS_MANTISBT_PROJECT' "$guests_yml" | tr -d '""')
        printf -v date '%(%Y%m%d-%H%M%S)T' -1
        if [ -z "$PR_NUM" ]; then
            pr_substr=_main
        else
            pr_substr=_$PR_NUM
        fi
        artifact_dirname=tmt-"$REPO_NAME""$pr_substr"_"$os"_"$date"/artifacts
        target_dir="/srv/pub/alt/linuxsystemroles/logs"
        ARTIFACTS_DIR="$target_dir"/"$artifact_dirname"
        ARTIFACTS_URL=https://dl.fedoraproject.org/pub/alt/linuxsystemroles/logs/$artifact_dirname/
    fi
    ssh -i "$id_rsa_path" -o StrictHostKeyChecking=no "$LINUXSYSTEMROLES_USER"@"$LINUXSYSTEMROLES_DOMAIN" mkdir -p "$ARTIFACTS_DIR"
    scp -i "$id_rsa_path" -o StrictHostKeyChecking=no "$logfile" "$LINUXSYSTEMROLES_USER"@"$LINUXSYSTEMROLES_DOMAIN":"$ARTIFACTS_DIR"/
    rlLogInfo "Logs are uploaded at $ARTIFACTS_URL"
}

rolesRunPlaybook() {
    local tests_path=$1
    local test_playbook=$2
    local inventory=$3
    local skip_tags=$4
    LOGFILE="${test_playbook%.*}"-ANSIBLE-"$ANSIBLE_VER"
    rlRun "ansible-playbook -i $inventory $skip_tags $tests_path$test_playbook -v &> $LOGFILE" 0 "Test $test_playbook with ANSIBLE-$ANSIBLE_VER"
    failed=$(grep 'PLAY RECAP' -A 1 "$LOGFILE" | tail -n 1 | grep -Po 'failed=\K(\d+)')
    rescued=$(grep 'PLAY RECAP' -A 1 "$LOGFILE" | tail -n 1 | grep -Po 'rescued=\K(\d+)')
    if [ "$failed" -gt "$rescued" ]; then
        logfile_name=$LOGFILE-FAIL.log
        mv "$LOGFILE" "$logfile_name"
        LOGFILE=$logfile_name
    else
        logfile_name=$LOGFILE-SUCCESS.log
        mv "$LOGFILE" "$logfile_name"
        LOGFILE=$logfile_name
    fi
    rolesUploadLogs "$LOGFILE"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.
#
#   This library does not do anything, it is only a list of functions, so simply returning 0
libraryLibraryLoaded() {
    rlLog "Library loaded!"
    return 0
}