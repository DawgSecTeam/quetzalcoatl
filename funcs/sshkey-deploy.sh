#!/bin/bash
# Old, was used for ansible
# format input like this: user1,ip1,pass1, user2,ip2,pass2

ssh-keygen -t rsa -f ~/.ssh/comp-ansible -N ""
echo "[vms]" > generated_inventory.ini

for entry in "$@"
do
    IFS=',' read -r REMOTE_USER IP PASS <<< "$entry"

    echo "$IP"

    sshpass -p "$PASS" ssh-copy-id -i ~/.ssh/comp-ansible -o StrictHostKeyChecking=no "$REMOTE_USER@$IP"

    echo "$IP ansible_user=$REMOTE_USER ansible_ssh_private_key_file=/home/$USER/.ssh/comp-ansible" >> generated_inventory.ini
done
