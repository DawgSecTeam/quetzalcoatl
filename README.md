# CyberDawgs Automation Suite
Courtesy of Dipa and Hamza

## Documentation
For information on what the scripts do/how they work/when to use them, visit the docs:
```
https://wiki.dawgsec.com
```
And check out the README in the `minzero` directory.

## To-do
- pipe baseline specific out to a file
- fix diff -y broken on alpine (install diffutils)
- Offline auditd installation
- Revise audit-rules file
- Dynamic auditd rule installtion script for watching binaries based on specific paths on different distros
- deploy runs backup and sends back to system executed from
- ensure busybox deploy actually works
- in-place deploy (try localhost on deploy)
- jumpstart script curled into shell that installs packages and pulls repo + runs deploy
- Toggle outgoing on and off for package installs in activate
- Investigate https://github.com/MZBCodes/NCAE-CyberGames/blob/main/Scripts/base_harden.sh
- Use inotifywait for watchdawg
- in standard baseline run linpeas as non-root
- Write fake shell to replace /bin/false (discord ping when used) or rbash
- Windows scripting :(


## To-done
- fixed many types and logic bugs across files
