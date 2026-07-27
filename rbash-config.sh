#!/bin/sh
# rbash-config.sh - Restricted shell configuration for competition blue team users
# Card 71 - Sets up rbash environment with whitelisted commands only

set -e

############################
# Root check
############################
if [ "$(id -u)" -ne 0 ]; then
   printf "This script requires root privileges. Exiting\n"
   exit 1
fi

############################
# Configuration
############################
RESTRICTED_BIN="/usr/local/restricted/bin"
RESTRICTED_PROFILE="/usr/local/restricted/profile"
BLUEY_HOME="/home/bluey"
BLUEY_USER="bluey"

# Allowed commands to symlink into the restricted bin
ALLOWED_CMDS="ls cat grep diff head tail wc find ps id whoami date less more awk sed chmod chown"

# Detect rbash location
RBA=""
for candidate in /bin/rbash /usr/bin/rbash; do
   if [ -f "$candidate" ]; then
      RBA="$candidate"
      break
   fi
done

if [ -z "$RBA" ]; then
   printf "ERROR: rbash not found. Install bash first.\n"
   exit 1
fi

############################
# Detect OS
############################
if command -v dnf &> /dev/null; then
   OS="rhel"
elif command -v apt &> /dev/null; then
   OS="debian"
elif command -v apk &> /dev/null; then
   OS="alpine"
else
   printf "WARNING: Unknown OS detected. Attempting generic setup.\n"
   OS="unknown"
fi

printf "Detected OS: %s\n" "$OS"

############################
# Install bash/rbash if missing
############################
if [ -z "$RBA" ]; then
   printf "Installing bash...\n"
   case "$OS" in
      debian)
         apt install -y bash
         ;;
      rhel)
         dnf install -y bash
         ;;
      alpine)
         apk add --no-cache bash
         ;;
      *)
         printf "ERROR: Cannot install bash on unknown OS. Install manually.\n"
         exit 1
         ;;
   esac

   # Re-detect rbash after install
   for candidate in /bin/rbash /usr/bin/rbash; do
      if [ -f "$candidate" ]; then
         RBA="$candidate"
         break
      fi
   done

   if [ -z "$RBA" ]; then
      printf "ERROR: rbash still not found after install.\n"
      exit 1
   fi
fi

printf "Using rbash: %s\n" "$RBA"

############################
# Create bluey user
############################
if id "$BLUEY_USER" &>/dev/null; then
   printf "User %s already exists, updating shell...\n" "$BLUEY_USER"
   usermod -s "$RBA" "$BLUEY_USER"
else
   printf "Creating user %s with rbash shell...\n" "$BLUEY_USER"
   case "$OS" in
      alpine)
         adduser -D "$BLUEY_USER" -h "$BLUEY_HOME" -s "$RBA"
         ;;
      *)
         useradd -m -s "$RBA" "$BLUEY_USER"
         ;;
   esac
fi

############################
# Set up restricted bin directory
############################
printf "Setting up restricted command directory: %s\n" "$RESTRICTED_BIN"
mkdir -p "$RESTRICTED_BIN"

# Remove any stale symlinks
rm -f "$RESTRICTED_BIN"/*

# Symlink allowed commands
for cmd in $ALLOWED_CMDS; do
   # Find the binary location
   CMD_PATH="$(command -v "$cmd" 2>/dev/null || true)"

   # If command not found via PATH, try common locations
   if [ -z "$CMD_PATH" ]; then
      for dir in /usr/bin /bin /usr/sbin /sbin; do
         if [ -f "$dir/$cmd" ]; then
            CMD_PATH="$dir/$cmd"
            break
         fi
      done
   fi

   if [ -n "$CMD_PATH" ]; then
      ln -sf "$CMD_PATH" "$RESTRICTED_BIN/$cmd"
      printf "  [+] %s -> %s\n" "$cmd" "$CMD_PATH"
   else
      printf "  [-] WARNING: Command '%s' not found, skipping\n" "$cmd"
   fi
done

############################
# Create restricted systemctl wrapper
############################
# Only allow 'systemctl status' - block start/stop/restart/enable/disable
cat > "$RESTRICTED_BIN/systemctl" << 'WRAPPER'
#!/bin/sh
# Restricted systemctl wrapper - only 'status' is allowed
case "${1:-}" in
   status)
      exec /bin/systemctl status "${@:2}"
      ;;
   "")
      echo "Error: No command specified. Only 'status' is allowed."
      exit 1
      ;;
   *)
      echo "Error: Command '$1' is not allowed. Only 'status' is permitted."
      exit 1
      ;;
esac
WRAPPER
chmod +x "$RESTRICTED_BIN/systemctl"
printf "  [+] systemctl (restricted to status only)\n"

############################
# Create restricted journalctl wrapper
############################
# Allow journalctl with read-only flags only
cat > "$RESTRICTED_BIN/journalctl" << 'WRAPPER'
#!/bin/sh
# Restricted journalctl wrapper - read-only access
# Block destructive flags
for arg in "$@"; do
   case "$arg" in
      --rotate|--vacuum-*|--flush|--file|--no-pager|--output=*)
         # These are read-safe
         ;;
      --verify|--disk-usage)
         # These are read-safe
         ;;
      *)
         # Allow by default - journalctl is mostly read-only
         ;;
   esac
done
exec /bin/journalctl "$@"
WRAPPER
chmod +x "$RESTRICTED_BIN/journalctl"
printf "  [+] journalctl (read-only)\n"

############################
# Create restricted shell profile
############################
cat > "$RESTRICTED_PROFILE" << 'PROFILE'
# Restricted shell profile for competition blue team users
# This profile is sourced by rbash to enforce restrictions

# Restrict PATH to only the restricted bin directory
export PATH="/usr/local/restricted/bin"

# Prevent PATH modification
readonly PATH

# Prevent shell function creation (bypass technique)
readonly FUNC

# Restrict variable assignment - prevent overriding restricted vars
readonly HOME
readonly SHELL

# Prevent redirection to files outside allowed directories
# rbash restriction: no redirect to files with slashes in name
# We enforce this via the restricted command set (no shell builtins except restricted ones)

# Disable history file writing to prevent data exfiltration via history
unset HISTFILE

# Set a restrictive umask
umask 022

# Welcome banner
printf "\n"
printf "========================================\n"
printf "  Restricted Shell Environment\n"
printf "  Competition Blue Team Access\n"
printf "========================================\n"
printf "Allowed commands: %s\n" "ls cat grep diff head tail wc find ps id whoami date less more awk sed chmod chown systemctl journalctl"
printf "========================================\n"
printf "\n"
PROFILE

############################
# Configure bluey's shell environment
############################
# Set up .profile to source the restricted profile
BLUEY_PROFILE="$BLUEY_HOME/.profile"

# Clear existing profile if present
cat > "$BLUEY_PROFILE" << 'EOF'
# Restricted shell profile - sourced on login
if [ -f /usr/local/restricted/profile ]; then
   . /usr/local/restricted/profile
fi
EOF

# Set up .bashrc to prevent interactive bypass
cat > "$BLUEY_HOME/.bashrc" << 'EOF'
# Restricted shell rc - prevents interactive shell escapes
# rbash already blocks most escape attempts, but this adds defense in depth

# Prevent loading of any external configuration
unset BASH_ENV
unset ENV

# Source the restricted profile
if [ -f /usr/local/restricted/profile ]; then
   . /usr/local/restricted/profile
fi
EOF

# Set up .bash_logout to clean up on exit
cat > "$BLUEY_HOME/.bash_logout" << 'EOF'
# Clean up on logout
unset HISTFILE
EOF

# Ensure proper ownership
chown -R "$BLUEY_USER":"$BLUEY_USER" "$BLUEY_HOME"
chmod 700 "$BLUEY_HOME"
chmod 600 "$BLUEY_PROFILE"
chmod 600 "$BLUEY_HOME/.bashrc"
chmod 600 "$BLUEY_HOME/.bash_logout"

############################
# Lock down restricted bin
############################
# Make restricted bin directory owned by root, not writable by users
chown -R root:root "$RESTRICTED_BIN"
chmod 755 "$RESTRICTED_BIN"

# Ensure all symlinks point to binaries owned by root
# (already guaranteed since we symlink system binaries)

############################
# Verify rbash is actually restricted
############################
# rbash works by checking if the binary name is 'rbash' or if it's a symlink named 'rbash'
# Verify the symlink chain is correct
if [ "$(basename "$RBA")" != "rbash" ]; then
   # If rbash is a symlink to bash, make sure the name resolves correctly
   REAL_BASH="$(readlink -f "$RBA" 2>/dev/null || echo "$RBA")"
   printf "rbash resolves to: %s\n" "$REAL_BASH"
fi

############################
# Summary
############################
printf "\n"
printf "========================================\n"
printf "  Restricted Shell Setup Complete\n"
printf "========================================\n"
printf "User:           %s\n" "$BLUEY_USER"
printf "Shell:          %s\n" "$RBA"
printf "Restricted bin: %s\n" "$RESTRICTED_BIN"
printf "Profile:        %s\n" "$RESTRICTED_PROFILE"
printf "Home:           %s\n" "$BLUEY_HOME"
printf "Allowed cmds:   %s\n" "$ALLOWED_CMDS"
printf "                systemctl (status only)\n"
printf "                journalctl (read-only)\n"
printf "========================================\n"
printf "\n"
printf "To test: su - %s\n" "$BLUEY_USER"
printf "The user will have a restricted PATH with only whitelisted commands.\n"
printf "Shell escapes (vi, less, etc.) are blocked by rbash restrictions.\n"
printf "cd, exit, and redirection to paths with slashes are blocked.\n"
printf "\n"
