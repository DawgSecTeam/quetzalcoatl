#!/bin/bash
# Install and configure PTP on Linux
# UNTESTED
# Does not function on alpine


if [ "$(id -u)" -ne 0 ]; then
  printf "This script requires root privileges. Exiting\n"
  exit 1
fi

PTP_CONFIG_FILE="/etc/linuxptp/ptp4l.conf"
PTP_INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)' | head -1)

systemctl disable --now chronyd
systemctl disable --now ntp
systemctl disable --now systemd-timesyncd

if command -v apt-get &> /dev/null; then
    apt-get update && apt-get install -y linuxptp
    OS_FAMILY="Debian"
elif command -v dnf &> /dev/null; then
    dnf install -y linuxptp
    OS_FAMILY="RedHat"
elif command -v yum &> /dev/null; then
    yum install -y linuxptp
    OS_FAMILY="RedHat"
fi

# Configuration
mkdir -p /etc/linuxptp
chmod 755 /etc/linuxptp

# Configure ptp4l.conf
cat <<EOF > "$PTP_CONFIG_FILE"
[global]
# b/c hardware is not accesible in vms
time_stamping       software
domainNumber        0
# prevents it from tryna start dishing out incorrect times
clientOnly           1
logging_level        6

[$PTP_INTERFACE]
EOF

# Create systemd service file (Debian only - as per playbook logic)
if [ "$OS_FAMILY" == "Debian" ]; then
    cat <<EOF > /lib/systemd/system/ptp4l.service
[Unit]
Description=Precision Time Protocol (PTP) service
After=network.target

[Service]
ExecStart=/usr/sbin/ptp4l -f /etc/linuxptp/ptp4l.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF
fi

# Create systemd override directory and file
mkdir -p /etc/systemd/system/ptp4l.service.d
chmod 755 /etc/systemd/system/ptp4l.service.d

cat <<EOF > /etc/systemd/system/ptp4l.service.d/override.conf
[Service]
# Clear previous ExecStart
ExecStart=
# Start with config file and specific interface detected earlier
ExecStart=/usr/sbin/ptp4l -f $PTP_CONFIG_FILE -i $PTP_INTERFACE
EOF

# Reload systemd, enable and restart service
systemctl daemon-reload
systemctl enable ptp4l
systemctl restart ptp4l

echo "PTP configuration complete and service started."
