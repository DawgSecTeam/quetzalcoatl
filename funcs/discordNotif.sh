ALERT_KEY1="recon"
ALERT_KEY2="susp_activity"
webhook=""

COMM="hi"
JSON='{"embeds":[{"title":"'$ALERT_KEY1'", "fields": [{"name": "PID", "value": "'$PID'"}]}]}'
echo "$PID"
echo "--- ALERT TRIGGERED ---"
curl -H "Content-Type: application/json" -d '{
   "embeds":[{"title":"Test Alert",
      "fields":[{"name":"COMM","value":"'$COMM'"},
                {"name":"PID","value":"'$PID'"},
                {"name":"PPID","value":"'$PPID'"},
                {"name":"UID","value":"'$UID'"}
               ]
            }]
   }' "$webhook" 
