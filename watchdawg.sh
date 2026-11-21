#!/bin/sh
printf "▗▖ ▗▖ ▗▄▖▗▄▄▄▖▗▄▄▖▗▖ ▗▖▗▄▄▄  ▗▄▖ ▗▖ ▗▖ ▗▄▄▖\n";
printf "▐▌ ▐▌▐▌ ▐▌ █ ▐▌   ▐▌ ▐▌▐▌  █▐▌ ▐▌▐▌ ▐▌▐▌   \n";
printf "▐▌ ▐▌▐▛▀▜▌ █ ▐▌   ▐▛▀▜▌▐▌  █▐▛▀▜▌▐▌ ▐▌▐▌▝▜▌\n";
printf "▐▙█▟▌▐▌ ▐▌ █ ▝▚▄▄▖▐▌ ▐▌▐▙▄▄▀▐▌ ▐▌▐▙█▟▌▝▚▄▞▘\n";
printf "                           Version 1.1.1   \n\n";

if [ "$1" != "" ] && [ "$2" != "" ]; then
   # directory to backup copies of files
   BACKUP_DIR=$1
   # input file which contains dirs and files to watch
   INPUT=$2
else
   printf "no arguments. \ninput backup directory and input file"
   exit
fi



mkdir -p "$BACKUP_DIR"
echo "Backup dir created"
LOG_DIR="/var/log/.wd/"
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/wd.log"
chattr +a /var/log/.wd/


# Directory entries get recursively expanded into a separate watchlist file
# (kept alongside $INPUT, e.g. /etc/kernel/watchlist), never back into $INPUT
# itself. Previously new entries were appended to $INPUT while it was still
# being read, which permanently grew /etc/kernel/sources on every restart.
WATCHLIST="$(dirname "$INPUT")/watchlist"
: > "$WATCHLIST"

# Read files and folders to watch
while IFS= read -r line; do
   if [ -d "$line" ]; then
      # handle folders: recurse with find into the watchlist file
      find "$line" -type f >> "$WATCHLIST"
   elif [ -f "$line" ]; then
      # handle files
      printf "adding file to watchlist: %s\n" "$line"
      echo "$line" >> "$WATCHLIST"
      cp -p --parents "$line" "$BACKUP_DIR"
   else
      printf "file or folder %s doesn't exist\n" "$line"
   fi
done < "$INPUT"

# Seed the backup dir with the initial contents of every expanded file
while IFS= read -r line; do
   [ -f "$line" ] || continue
   [ -f "$BACKUP_DIR$line" ] || cp -p --parents "$line" "$BACKUP_DIR"
done < "$WATCHLIST"


while true; do
   while IFS= read -r line; do
      [ -f "$line" ] || continue
      diff -q "$line" "$BACKUP_DIR$line"
      DIFF_EXIT_CODE=$?


      if [ "$DIFF_EXIT_CODE" -eq 1 ]; then
         echo "============" >> "$LOG_DIR/wd.log"
         echo "Woof! File change detected on file $line"
         echo "CHANGE on file $line at $(date)" >> "$LOG_DIR/wd.log"
         diff "$line" "$BACKUP_DIR$line" >> "$LOG_DIR/wd.log"
         cp -p "$line" "$BACKUP_DIR$line"
      fi
   done < "$WATCHLIST"

   sleep 3
done


# v1.0.0 -> watch files and output changes to log
# v1.1.0 -> add support for watching directories
# v1.1.1 -> mark only .wd dir as append only instead of /var/log
# v1.1.2 -> expand directories into a separate watchlist file instead of the sources file
