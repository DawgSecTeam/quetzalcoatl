#!/bin/sh
set -e
echo "[*] Applying hardened firewall rules..."

if ! command -v iptables > /dev/null; then
 if command -v apt > /dev/null; then
	apt install -y iptables
 fi
fi

if command -v apk > /dev/null; then
 apk add -q iptables
 rc-update add iptables
 rc-service iptables save
fi

#precaution
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT

# Flush existing rules
iptables -F
iptables -X
iptables -t nat -F
iptables -t mangle -F

# Loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established / related
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --------------------------------------------------
# Allow inbound traffic ONLY to listening TCP ports
# --------------------------------------------------
IN=$(head -n1 /var/tmp/port-sources)
OUT=$(tail -n1 /var/tmp/port-sources)

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
# Optional logging (rate limited)
# --------------------------------------------------
iptables -A INPUT  -m limit --limit 5/min -j LOG --log-prefix "DROP_INPUT "
iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "DROP_OUTPUT "

# Default deny
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Drop invalid early
iptables -A INPUT  -m conntrack --ctstate INVALID -j DROP
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
