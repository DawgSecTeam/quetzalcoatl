#!/bin/sh
# Harden automatic v0.0.1

# Enforce root
if ! [ "$(id -u)" = 0 ]; then
   echo "Rerun with sudo"
   exit 1
fi

# Backup important files before modification
printf "Backing up passwd and shadow"
cp -p /etc/passwd /etc/.passwd
cp -p /etc/shadow /etc/.shadow
printf " [DONE]\n"
chattr -i /etc/passwd
chattr -i /etc/shadow

# Set all user shells to /bin/false, preventing login
sed -ri 's@(:[^:]*$)@:/bin/false@' /etc/passwd

# Add blueteam user
if command -v apk > /dev/null; then
   adduser bluey -h /home/bluey -s /bin/sh
else
   useradd bluey -m -s /bin/sh
fi
printf "Added bluey\n"
rm -rf /home/bluey/*
rm -rf /home/bluey/.*
printf "Cleaned up home directory\n"

if getent group wheel >/dev/null; then
   usermod -aG wheel bluey
   addgroup bluey wheel
   if command -v apk > /dev/null; then
      echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel
      chmod 0440 /etc/sudoers.d/wheel
   fi
else
   usermod -aG sudo bluey
fi

printf "Added to sudoers group\n"

printf "Setting password for root & bluey user\n"
hashed="$1"

printf "Received: %s\n" "$hashed"

sed -i "s|^bluey:[^:]*|bluey:$hashed|" /etc/shadow
chmod 644 /etc/passwd
chmod 600 /etc/shadow

# List of users to keep unlocked
ALLOWED_USERS="nobody bluey"

# Function to check if a user is in the allowed list
is_allowed() {
    for allowed_user in $ALLOWED_USERS; do
        if [ "$allowed_user" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

# Lock all users except the allowed ones
awk -F: '$3 < 1000 {print $1}' /etc/passwd | while read user; do
    if is_allowed "$user"; then
        continue
    fi

    sed -i "s/^\($user:\)\([^!]\)/\1!\2/" /etc/shadow
done

echo "/bin/false file size: "
ls -lh /bin/false

chattr +i /etc/passwd
chattr +i /etc/shadow
chattr +i /etc/group

shred -uf /var/tmp/pass_*