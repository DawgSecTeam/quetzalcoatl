#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
  printf "[x] This script requires root privileges. Exiting\n"
  exit 1
fi

IN=$(head -n1 /var/tmp/port-sources)
OUT=$(tail -n1 /var/tmp/port-sources)
download_ports=false
nuke=false

# parse flags
while [ $# -gt 0 ]; do
  case $1 in
  -h | --help)
    cat <<EOF
[*] Displaying the help menu
Valid flags:
  -h | --help       Displays this help menu
  -c | --clear      Clears the firewall of all rules and sets default allow
  -d | --download   Unlocks port 80 and 53 reguardless of the port sources
                    to allow package managers to download files.
EOF
    #      -s | --source     Specify a source file
    exit 0
    ;;

  -c | --clear)
    echo "[*] Nuking firewall"
    nuke=true
    shift $#
    ;;

  # enables ports required by package managers
  -d | --download)
    echo "[*] Enabled package manager ports 80 and 53"
    download_ports=true
    shift 1
    ;;

  -*)
    echo "[x] unrecognized flag"
    echo "For more information use the \"-h\" flag"
    exit 1
    ;;

  *)
    shift 1
    ;;
    # someone else can add this feature if needed (potential input injection vulnerability)
    # -s|--source)
    #   echo "[*] Attempting to set ports source"
  esac
done

if [ "$nuke" = false ]; then
  echo "[*] Applying hardened firewall rules..."
fi

# Stop and disable ufw/firewalld to prevent collisions
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^firewalld\.service'; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    systemctl mask firewalld 2>/dev/null || true
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^ufw\.service'; then
    systemctl stop ufw 2>/dev/null || true
    systemctl disable ufw 2>/dev/null || true
  fi
fi

if command -v ufw >/dev/null 2>&1; then
  ufw disable 2>/dev/null || true
fi

#precaution
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

if [ "$nuke" = true ]; then
  echo "[✓] Firewall is no longer"
  exit 0
fi

# Loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established / related
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --------------------------------------------------
# Allow inbound traffic ONLY to listening TCP ports
# --------------------------------------------------

#INBOUND
for port in $IN; do
  printf "[+] Allow inbound TCP port $port\n"
  iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
  printf "[+] Allow inbound UDP port $port\n"
  iptables -A INPUT -p udp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
done

printf "[+] Deny outbound ICMP\n"
iptables -A OUTPUT -p icmp -j DROP

#OUTBOUND
for port in $OUT; do
  printf "[+] Allow outbound TCP port $port\n"
  iptables -A OUTPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
  printf "[+] Allow outbound UDP port $port\n"
  iptables -A OUTPUT -p udp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
done

# ICMP
iptables -A INPUT -p icmp -j ACCEPT

# --------------------------------------------------
# Allows port 80 and port 53 if applicable
# --------------------------------------------------
if [ $download_ports = true ]; then
  printf "[+] Allow outbound UDP port 53 (DNS)\n"
  iptables -A OUTPUT -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT

  printf "[+] Allow outbound TCP port 80\n"
  iptables -A OUTPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT

  if command -v dnf &> /dev/null; then
    printf "[+] Allow outbound TCP port 443\n"
    iptables -A OUTPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
  fi

fi

# --------------------------------------------------
# Optional logging (rate limited)
# --------------------------------------------------
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "DROP_INPUT "
iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "DROP_OUTPUT "

# Default deny
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Drop invalid early
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP

# Allow vertical
iptables -A INPUT -s 192.168.111.0/24 -j ACCEPT
iptables -A OUTPUT -s 192.168.111.0/24 -j ACCEPT

#v6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1

ip6tables -P INPUT DROP
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP

echo "[*] Saving iptable rules across reboot..."

mkdir -p /etc/iptables
iptables-save -f /etc/iptables/iptables.rules
ip6tables-save -f /etc/iptables/ip6tables.rules

echo "[✓] Firewall locked down successfully."

# autofirewall.sh automatically logs dropped packets to /var/log/syslog or /var/log/messages
# to view the specific ones, use `cat /var/log/syslog | grep "DROP_OUTPUT" > messages`
