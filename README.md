# DawgSec Automation Suite
Courtesy of Dipa and Hamza

## Documentation
For information on what the scripts do/how they work/when to use them, read the code or ask an LLM.
More deploy documentation in the `baseline`, `minzero`, and `systems` directory READMEs.
To run a full end-to-end deploy test against live VMs, see `TESTING.md`.

## Modification policy
**Changes:** Makes all changes on new branches, and ensure the full suite is thoroughly tested before merging. Commits on an unmerged branch are allowed to break functionality, as long as everything is fixed by the time a PR is made.

**Competitions:** When adding anything to the `systems/` directory for a specific competition, clone the repository, so nothing in the main repo is modified. Everything in that directory is currently .gitignored, as is `minzero/hostfile`, so you will need to modify the gitignore for the cloned repo.


## Usage
```
Stage 0 (clean box)      Stage 1-2 (operator host)          Stage 3 (each target, root)
┌────────────────┐       ┌────────────────────────┐         ┌──────────────────────────┐
│ backup.sh      │       │ hostfile + port-sources│  ssh    │ baseline/standard.sh     │
│ baseline       │──┐    │        │               │ ──────► │ baseline/specific.sh     │
│ → baseline.    │  │    │        ▼               │ sshpass │                          │
│   tar.gz       │  └───►│ minzero/deploy.sh      │ +parallel                          │
└────────────────┘ (copy │        │               │         │                          │
 clean snapshot into     │        ▼               │         │                          │
 systems/<name>/)        │  activate.sh           │         │                          │
                         │  ├ autofirewall.sh     │         │                          │
                         │  └ harden.sh           │         │                          │
                         └────────────────────────┘         └──────────────────────────┘
```

### Stage 0 — Clean snapshot [Docs: baseline/README.md]
0.1 Install the scored services on a clean box to mirror the target  
0.2 Run `backup.sh baseline`  
0.3 Copy that `baseline.tar.gz` into each `systems/<name>/`

### Stage 1 — Operator prep [Docs: minzero/README.md]
1.1 Create the hostfile  
1.2 Write the `systems/port-sources` file to allow only expected ports

### Stage 2 — Deploy [Docs: minzero/README.md]
2.1 Run `minzero/deploy.sh` which reads `./hostfile`, and for each host copies over
  `port-sources` and `systems/<name>/`

### Stage 3 — Baseline [Docs: baseline/README.md]
3.1 Run `baseline/standard.sh` and `baseline/specific.sh` which provide info on the
  state of the compromised system
