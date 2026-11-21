#!/bin/sh

IN_TCP=$(sed '1q;d' /var/tmp/port-sources)
OUT_TCP=$(sed '2q;d' /var/tmp/port-sources)
IN_UDP=$(sed '3q;d' /var/tmp/port-sources)
OUT_UDP=$(sed '4q;d' /var/tmp/port-sources)

IN_T=$(echo "$IN_TCP" | sed 's/ /, /')
printf "static const int IN_PORTS_TCP[] = {$IN_T};\n" > config.h
OUT_T=$(echo "$OUT_TCP" | sed 's/ /, /')
printf "static const int OUT_PORTS_TCP[] = {$OUT_T};\n" >> config.h
IN_U=$(echo "$IN_UDP" | sed 's/ /, /')
printf "static const int IN_PORTS_UDP[] = {$IN_U};\n" >> config.h
OUT_U=$(echo "$OUT_UDP" | sed 's/ /, /')
printf "static const int OUT_PORTS_UDP[] = {$OUT_U};\n" >> config.h
printf "static unsigned int DEFAULT_RULE = NF_DROP;\n" >> config.h

rmmod dawgfilter
make && insmod dawgfilter.ko
