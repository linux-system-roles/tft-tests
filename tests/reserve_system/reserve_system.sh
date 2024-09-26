#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test parameters:
# ID_RSA_PUB
#   Your id_rsa_pub that this test distributes to all nodes so that you can SSH into them.

rlJournalStart
    rlPhaseStartSetup
        rlRun "rlImport library"
        lsrPrepTestVars
        # Distribute user's id_rsa_pub. Otherwise 1minutetip or tft-artemis-master-key key can be used.
        if [ -n "$ID_RSA_PUB" ]; then
            # guests_yml and tmt_tree_provision is defined in lsrPrepTestVars
            # shellcheck disable=SC2154
            control_node_name=$(yq -r ". | keys[] | select(test(\"control*\"))" "$guests_yml")
            # shellcheck disable=SC2154
            control_node_id_rsa=$tmt_tree_provision/$control_node_name/id_ecdsa
            echo "$ID_RSA_PUB" >> ~/.ssh/authorized_keys
            user_id_rsa_pub_path=$(mktemp -t user_id_rsa_pub-XXX)
            echo "$ID_RSA_PUB" > "$user_id_rsa_pub_path"
            managed_nodes=$(lsrGetManagedNodes "$guests_yml")
            for managed_node in $managed_nodes; do
                managed_node_ip=$(yq -r ".\"$managed_node\".\"primary-address\"" "$guests_yml")
                rlRun "scp -i $control_node_id_rsa -o StrictHostKeyChecking=no $user_id_rsa_pub_path root@$managed_node_ip:/tmp/user_id_rsa_pub"
                rlRun "ssh -i $control_node_id_rsa -o StrictHostKeyChecking=no root@$managed_node_ip 'cat /tmp/user_id_rsa_pub >> ~/.ssh/authorized_keys'"
            done
        fi
        sleep 301m &
    rlPhaseEnd
rlJournalEnd
