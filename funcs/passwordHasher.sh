#!/bin/sh
if [ "$#" -eq 0 ]; then
  printf "Pass password in first arg\n"
  exit 1
fi
salt=$(openssl rand -hex 16)
hashed_password=$(openssl passwd -6 -salt "$salt" "$1")
printf "%s" "$hashed_password"
