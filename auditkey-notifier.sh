#!/bin/sh
# When auditd rules are triggered, sends a discord notification
# Uses flags exclusive to GNU grep!!

# Configuration
SOCKET_PATH="/var/run/audispd_events"
ALERT_KEY1="recon"
ALERT_KEY2="susp_activity"
# YOU NEED TO FILL THE webhook VARIABLE TO MAKE THE PROGRAM WORK
echo "Starting Auditd Socket Listener..."

# -U is for Unix Socket. 
# We use 'case' instead of 'grep' to avoid triggering new audit events.
nc -U "$SOCKET_PATH" | while read -r line; do
    
    case "$line" in
        *"$ALERT_KEY1"*)
	    PID=$(echo "$line" | grep -oP '\bpid=\K\d+')
	    COMM=$(echo "$line" | grep -oP '\bcomm="\K[^"]+')
	    PPID=$(echo "$line" | grep -oP 'ppid=\K\d+')
	    UID=$(echo "$line" | grep -oP '\buid=\K\d+')
	    JSON='{"embeds":[{"title":"'$ALERT_KEY1'", "fields": [{"name": "PID", "value": "'$PID'"}]}]}'
	    echo "$PID"

            echo "--- ALERT TRIGGERED ---"
	    curl -H "Content-Type: application/json" -d '{"embeds":[{"title":"'$ALERT_KEY1'","fields":[{"name":"COMM","value":"'$COMM'"},{"name":"PID","value":"'$PID'"},{"name":"PPID","value":"'$PPID'"},{"name":"UID","value":"'$UID'"}]}]}' "$webhook" 
            echo "$line"
            ;;
    esac
    case "$line" in
        *"$ALERT_KEY2"*)
	    PID=$(echo "$line" | grep -oP '\bpid=\K\d+')
	    COMM=$(echo "$line" | grep -oP '\bcomm="\K[^"]+')
	    PPID=$(echo "$line" | grep -oP 'ppid=\K\d+')
	    UID=$(echo "$line" | grep -oP '\buid=\K\d+')
	    JSON='{"embeds":[{"title":"'$ALERT_KEY2'", "fields": [{"name": "PID", "value": "'$PID'"}]}]}'
	    echo "$PID"

            echo "--- ALERT TRIGGERED ---"
	    curl -H "Content-Type: application/json" -d '{"embeds":[{"title":"'$ALERT_KEY2'","fields":[{"name":"COMM","value":"'$COMM'"},{"name":"PID","value":"'$PID'"},{"name":"PPID","value":"'$PPID'"},{"name":"UID","value":"'$UID'"}]}]}' "$webhook" 
	    echo "$line"
            ;;
    esac
done
