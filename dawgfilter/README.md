# dawgfilter, vendored

Source: `git@github.com:dawgSecTeam/dawgfilter` (private), commit `ab284d2` — vendored
because `dawgfirewall.sh` builds the module **on the target** at deploy time and
competition boxes are often air-gapped; a build that needs GitHub at deploy time is a
build that fails at the worst moment.

Update the vendored copy with:

```sh
git clone git@github.com:dawgSecTeam/dawgfilter.git /tmp/dawgfilter
cp /tmp/dawgfilter/Makefile /tmp/dawgfilter/dawgfilter.c dawgfilter/
# re-apply the local changes below, then rebuild (see .github/workflows/dawgfilter-build.yml)
```

## Local changes against upstream

1. **Inbound filtering is destination-port only.** Upstream's `hook_in` also accepted any
   inbound packet whose *source* port was in the outbound list (`src_port ∈ OUT_PORTS`).
   That is a bypass, not a shortcut: with the sample config, `--source-port 443` reached
   every port on the box, including unprivileged listeners on 8000/9000/6767. The rule was
   there to let replies to outbound connections back in — it is replaced by
   conntrack state plus a reply-shape check (2).

2. **Replies are recognised, not guessed.** `ct_is_reply()` uses `nf_ct_get()` — a static
   inline over `skb->_nfct`, so the module still loads and filters on a kernel where
   conntrack never attaches. When conntrack is unavailable the fallback is
   `looks_like_stateless_reply()`: destination port ≥ 32768 (an ephemeral port) **and**
   source port in the outbound list **and**, for TCP, no SYN. A SYN is never a reply, so
   the original bypass stays closed; without this fallback every `apt`/DNS reply is
   dropped on the images where conntrack does not attach (observed on Ubuntu 24.04 and
   Debian 13 cloud kernels).

3. **OUTPUT accepts `src_port ∈ IN_PORTS`.** Kept from upstream, and it is what keeps a
   server's SYN-ACK leaving the box when conntrack is dead. It is an egress channel for a
   root-owned port only; the box is already lost if an attacker can bind 22/80.

4. **No per-packet `pr_info`.** Upstream logged every non-TCP/UDP packet; a default-deny
   filter turns that into a log flood (and a DoS) on any ICMP scan.

5. `KDIR ?=` so CI can build against a container's headers (inside a container,
   `uname -r` is the host runner's kernel).

## Limits, stated rather than implied

- **IPv4 only.** `dawgfirewall.sh` disables IPv6 instead of pretending it is covered.
- **LOCAL_IN / LOCAL_OUT only.** A box used as a router is not filtered by this module.
- **No connection tracking means no true state.** With conntrack unavailable the filter is
  an approximation: replies must arrive on an ephemeral port from an allowed service port.
  Documented here because a competition box running that way is weaker than its config
  suggests.
