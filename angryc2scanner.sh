#!/bin/sh
# Like c2scanner but ANGRY
# It will murder (in cold blood!) any process attempting to reach out to the world

if [ "$(id -u)" -ne 0 ]; then
  printf "How are you going to commit murder as anything other than root? Exiting\n"
  exit 1
fi

mkdir -p scans

FNAME="$(date +%s)"
FNAME_LAST="$(date +%s)ProMax"

while true
do
  FNAME="$(date +%s)"
  ss --no-header -tupn > "scans/$FNAME"

  DIFF=$(diff "scans/$FNAME" "scans/$FNAME_LAST")
  if [ "$DIFF" != "" ];
  then
    echo "====== NEW STUFF HAPPENING ======"
    echo "event at $(date)"
    diff "scans/$FNAME" "scans/$FNAME_LAST"

    echo "====== COMMITING MURDER ======"
    ss -tpn | grep -Po 'pid=\K[0-9]+' > hitlist
    while IFS= read -r line; do
       # Leave important processes alone
       #pname=$(ps -p "$line" -o comm=)
       #incomplete

       ppid=$(ps --no-headers -fp "$line" | awk '$1 { print $3 }')
       kill -9 "$line"
       # this could loop maybe, be more careful
       while [ "$ppid" != "$line" ] && [ "$ppid" != "1" ]; do
         prev=$ppid
         ppid=$(ps --no-headers -fp "$prev" | awk '$1 { print $3 }')
         kill -9 "$prev";
         echo "done murding $prev"
         done
       echo "done murding $line"
    done < hitlist
  fi

  FNAME_LAST=$FNAME

  sleep .5
done
