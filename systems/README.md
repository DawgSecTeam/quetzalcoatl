### Make dirs for every box and put sourcefiles in there
Example: `mkdir web`
 - Make sure the name of the dir is the same as the second value in the hostfile
 - Current required sourcefile is `port-sources`
port sorces goes (space seperated):
IN_TCP
OUT_TCP
IN_UDP
OUT_UDP
LAN_RANGE

It's expected to look like
system/
   db/
      baseline.tar.gz
      port-sources
   web/
      baseline.tar.gz
      port-sources
