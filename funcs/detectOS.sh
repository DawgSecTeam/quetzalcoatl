#!/bin/sh

if command -v dnf &> /dev/null; then
   echo "rhel"
elif command -v apt &> /dev/null; then
   echo "debian"
elif command -v zypper &> /dev/null; then
   echo "opensuse"
elif command -v apk &> /dev/null; then
   echo "alpine"
elif command -v pacman &> /dev/null; then
   echo "arch"
else
   echo "What are you using, Solaris?"
fi
