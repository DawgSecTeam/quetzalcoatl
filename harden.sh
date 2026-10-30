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

ln -s /bin/bash /bin/rbash

#sets uid >= 1000 to rbash
awk -F: '$3 >= 1000 && $1 != "nobody" {print FNR}' /etc/passwd | while read line; do
    sed -ri " $line s@(:[^:]*$)@:/bin/rbash@" /etc/passwd
done
#sets uid < 1000 to /bin/false
awk -F: '$3 < 1000 || $1 == "nobody" {print FNR}' /etc/passwd | while read line; do
    sed -ri " $line s@(:[^:]*$)@:/bin/false@" /etc/passwd
done

#sets path of rbash users to the /rbin folder and prevent user from changing stuff
awk -F: '$7 == "/bin/rbash" {print $6}' /etc/passwd | while read home; do
    echo "export PATH=/rbin" >> ${home}/.bash_profile
    echo "export PATH=/rbin" >> ${home}/.bashrc

    chown root:root ${home}/.bashrc
    chown root:root ${home}/.bash_profile
    chown root:root ${home}/.profile 2>/dev/null
    chown root:root ${home}/.bash_logout 2>/dev/null
    chmod 744 ${home}/.bashrc 
    chmod 744 ${home}/.bash_profile
    chmod 744 ${home}/.profile 2>/dev/null
    chmod 744 ${home}/.bash_logout 2>/dev/null
done

mkdir /rbin
chown root:root /rbin
chmod 755 /rbin

#allow restricted user to do stuff
ln -s /bin/ls /rbin/ls
ln -s /bin/whoami /rbin/whoami
ln -s /bin/id /rbin/id


chattr +i /rbin
printf "Configured rbash stuff\n"

# Add blueteam user
if command -v apk > /dev/null; then
   adduser -D bluey -h /home/bluey -s /bin/sh
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