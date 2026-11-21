#!/bin/sh
set -e 

if [ "$(id -u)" -ne 0 ]; then
  printf "[x] This script requires root privileges. Exiting\n"
  exit 1
fi


IN_TCP=$(sed '1q;d' /var/tmp/port-sources)
OUT_TCP=$(sed '2q;d' /var/tmp/port-sources)
IN_UDP=$(sed '3q;d' /var/tmp/port-sources)
OUT_UDP=$(sed '4q;d' /var/tmp/port-sources)


printf "Installing kernel headers...\n"

if command -v apt > /dev/null; then
  apt install -y linux-headers-$(uname -r) gcc make
fi

if command -v apk > /dev/null; then
  apk add -q linux-headers build-base
fi

if command -v pacman > /dev/null; then
  pacman -S --noconfirm linux-headers
fi

if command -v dnf > /dev/null; then
  dnf install kernel-devel kernel-headers gcc make -y
fi

make && insmod dawgfilter.ko
