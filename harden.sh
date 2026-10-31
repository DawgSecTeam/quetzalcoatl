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

cp /var/tmp/binaries/bash /bin

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

#fix for sed not found
if command -v yum > /dev/null; then
    sudo rm -f /etc/profile.d/80-systemd-osc-context.sh
    sudo ln -sf /dev/null /etc/tmpfiles.d/20-systemd-osc-context.conf
fi


mkdir /rbin
chown root:root /rbin
chmod 755 /rbin

#allow restricted user to do stuff
ln -s /opt/busybox/busybox /rbin/ls
ln -s /opt/busybox/busybox /rbin/whoami
ln -s /opt/busybox/busybox /rbin/id


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

# Pick the admin group that actually exists here (sudo uses "sudo" on
# Debian/Ubuntu, "wheel" everywhere else; some Alpine images have neither).
if getent group sudo >/dev/null 2>&1; then
   ADMIN_GROUP=sudo
elif getent group wheel >/dev/null 2>&1; then
   ADMIN_GROUP=wheel
else
   ADMIN_GROUP=wheel
   groupadd wheel 2>/dev/null || addgroup wheel 2>/dev/null
fi

# usermod is not part of busybox (Alpine ships it in pwdutils), so fall back to
# addgroup and then to a direct /etc/group edit.
if command -v usermod >/dev/null 2>&1; then
   usermod -aG "$ADMIN_GROUP" bluey
elif command -v addgroup >/dev/null 2>&1; then
   addgroup bluey "$ADMIN_GROUP"
else
   # Last resort (neither usermod nor addgroup): rewrite the group line with awk.
   awk -F: -v OFS=: -v g="$ADMIN_GROUP" '
      $1 == g { if (index("," $4 ",", ",bluey,") == 0) $4 = ($4 == "" ? "bluey" : $4 ",bluey") }
      { print }
   ' /etc/group > /etc/group.dawgtmp && chown root:root /etc/group.dawgtmp && chmod 644 /etc/group.dawgtmp && mv /etc/group.dawgtmp /etc/group
fi

# Grant escalation with whatever the box actually provides. Alpine images use
# doas, not sudo: writing /etc/sudoers.d/wheel there did nothing (the directory
# does not even exist) while still printing "Added to sudoers group".
GRANTED=""
if command -v sudo >/dev/null 2>&1; then
   mkdir -p /etc/sudoers.d
   printf '%%%s ALL=(ALL) ALL\n' "$ADMIN_GROUP" > /etc/sudoers.d/dawg-bluey
   chmod 0440 /etc/sudoers.d/dawg-bluey
   if command -v visudo >/dev/null 2>&1; then
      visudo -cf /etc/sudoers.d/dawg-bluey || printf "WARNING: sudoers snippet failed validation\n"
   fi
   GRANTED="sudo"
fi
if command -v doas >/dev/null 2>&1; then
   touch /etc/doas.conf
   chmod 0600 /etc/doas.conf
   # doas.conf has no command field: the syntax is "permit :group" (or
   # "permit nopass :group"), NOT sudo's "%group ALL". Writing "%wheel ALL"
   # makes doas abort with "syntax error" and disables escalation entirely.
   # Ignore commented-out lines: stock images ship "# permit persist :wheel".
   if ! grep -v '^[[:space:]]*#' /etc/doas.conf | grep -qs ":$ADMIN_GROUP"; then
      printf 'permit :%s\n' "$ADMIN_GROUP" >> /etc/doas.conf
   fi
   # Only treat explicit config errors as fatal: doas -C can also return
   # non-zero for authorization reasons, which must not abort hardening.
   doas_check=$(doas -C /etc/doas.conf true 2>&1)
   case "$doas_check" in
      *syntax*|*invalid*|*"no such file"*)
         printf "FATAL(23): /etc/doas.conf failed validation - bluey cannot escalate\n"
         printf '%s\n' "$doas_check"
         exit 23 ;;
   esac
   GRANTED="${GRANTED:+$GRANTED + }doas"
fi

# Verify the grant instead of asserting it.
if [ -z "$GRANTED" ]; then
   printf "FATAL(20): neither sudo nor doas is installed - bluey has no escalation path\n"
   exit 20
fi
in_group=$(awk -F: -v g="$ADMIN_GROUP" '$1==g { print (index("," $4 ",", ",bluey,") > 0) ? "yes" : "no" }' /etc/group)
if [ "$in_group" != "yes" ]; then
   printf "FATAL(21): bluey is not in group %s - escalation will fail\n" "$ADMIN_GROUP"
   exit 21
fi
printf "Granted %s via group %s\n" "$GRANTED" "$ADMIN_GROUP"

printf "Setting bluey password (root stays locked)\n"
hashed="$1"

# A mangled argument here silently overwrites bluey's hash and locks everybody
# out (root is locked and every other shell is /bin/false), so validate it.
case "$hashed" in
   *'$'*'$'*) printf "Received: %s\n" "$hashed" ;;
   *) printf "FATAL(22): argument is not a crypt() hash - refusing to touch /etc/shadow\n"
      exit 22 ;;
esac

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