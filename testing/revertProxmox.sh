#!/bin/bash
source ./.env
URL=https://realm.dawgsec.com/
printf "Reverting Ubutu\n"
curl -XPOST --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/134/snapshot/base/rollback 
printf "\nReverting Debian\n"
curl -XPOST --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/131/snapshot/base/rollback 
printf "\nReverting Fedora\n"
curl -XPOST --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/142/snapshot/base/rollback 
printf "\nReverting Alpine\n"
curl -XPOST --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/141/snapshot/base/rollback 
printf "\n"

sleep 5;

status1=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/134/status/current | jq .data.status)
status2=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/131/status/current | jq .data.status) 
status3=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/142/status/current | jq .data.status)
status4=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/141/status/current | jq .data.status)
while [ "$status1" != '"running"' ] || [ "$status2" != '"running"' ] || [ "$status3" != '"running"' ] || [ "$status4" != '"running"' ]; do
  if [ "$status1" != '"running"' ];then
    status1=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/134/status/current | jq .data.status)
    printf "Vm1: $status1\n"
  fi
  if [ "$status2" != '"running"' ];then
    status2=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/131/status/current | jq .data.status) 
    printf "Vm2: $status2\n"
  fi
  if [ "$status3" != '"running"' ];then
    status3=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/142/status/current | jq .data.status) 
    printf "Vm3: $status3\n"
  fi
  if [ "$status4" != '"running"' ];then
    status4=$(curl --silent --insecure -H "Authorization: $api_token" "$URL"api2/json/nodes/proxmox/qemu/141/status/current | jq .data.status) 
    printf "Vm4: $status4\n"
  fi
  if [ "$status1" = "running" ] && [ "$status2" = "running" ] && [ "$status3" = "running" ] && [ "$status4" = "running" ];then
    printf "[DONE]\n"
    exit 1;
  fi
  sleep 1;
done
printf "All vms completed reverting\n"
