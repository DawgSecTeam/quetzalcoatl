// dawgfilter — default-deny IPv4 packet filter as a netfilter module.
//
// Vendored from git@github.com:dawgSecTeam/dawgfilter (ab284d2) and patched for
// quetzalcoatl (see dawgfilter/README.md, "Local changes"). Build flags and the
// port lists come from config.h, which dawgfirewall.sh generates from the
// target's /var/tmp/port-sources at deploy time.
//
// Hooks sit at NF_IP_PRI_CONNTRACK + 1 on LOCAL_IN and LOCAL_OUT, so they see
// packets after conntrack has classified them but before iptables' filter
// table. Everything not explicitly allowed hits DEFAULT_RULE (NF_DROP).
//
// Deliberate limits, all documented in the integration README:
//   * IPv4 only — dawgfirewall.sh disables IPv6 instead of pretending to cover it
//   * LOCAL_IN/LOCAL_OUT only — a box used as a router is not filtered
//   * no per-packet logging — a log line per packet is a self-inflicted DoS

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/skbuff.h>
#include <net/route.h>
#include <net/ip.h>
// nf_ct_get() is a static inline that reads skb->_nfct: it needs no exported
// symbol and returns NULL when conntrack has not run, so the module still loads
// and filters (statelessly) on a kernel with conntrack disabled.
#include <net/netfilter/nf_conntrack.h>
#include <linux/netfilter/nf_conntrack_common.h>
#include "config.h"

static struct nf_hook_ops nfho_in;
static struct nf_hook_ops nfho_out;

// True when conntrack already decided this packet belongs to an existing flow.
// This is what makes the filter stateful when conntrack is available: replies
// are accepted without guessing from port numbers.
static bool ct_is_reply(struct sk_buff *skb)
{
	enum ip_conntrack_info ctinfo = IP_CT_NEW;
	struct nf_conn *ct = nf_ct_get(skb, &ctinfo);

	if (ct == NULL)
		return false;
	return ctinfo == IP_CT_IS_REPLY || ctinfo == IP_CT_ESTABLISHED_REPLY ||
	       ctinfo == IP_CT_RELATED_REPLY;
}

static bool in_list(const int *list, int len, int port)
{
	int i;

	for (i = 0; i < len; i++)
		if (list[i] == port)
			return true;
	return false;
}

// Would this packet have been a reply to a connection this box opened? The
// answer we can give without conntrack: it lands on an ephemeral port and comes
// from a port we allow outbound. A SYN is never a reply, which is what keeps
// this from re-opening the hole the original IN hook had (it accepted any
// inbound packet whose SOURCE port was in the outbound list, so `--source-port
// 443` reached every port on the box).
static bool looks_like_stateless_reply(int proto, int src_port, int dst_port,
				       bool is_syn)
{
	if (dst_port < 32768)
		return false;
	if (!in_list(proto == IPPROTO_TCP ? OUT_PORTS_TCP : OUT_PORTS_UDP,
		     proto == IPPROTO_TCP
			     ? (int)(sizeof(OUT_PORTS_TCP) / sizeof(OUT_PORTS_TCP[0]))
			     : (int)(sizeof(OUT_PORTS_UDP) / sizeof(OUT_PORTS_UDP[0])),
		     src_port))
		return false;
	// TCP: a listener's legitimate reply never carries SYN.
	if (proto == IPPROTO_TCP && is_syn)
		return false;
	return true;
}

//main OUTPUT hook func
static unsigned int hook_out(void *priv, struct sk_buff *skb,
			     const struct nf_hook_state *state)
{
	struct iphdr *iph = ip_hdr(skb);
	int src_port, dst_port, len_in, len_out;
	const int *out_list, *in_list_p;
	bool tcp = iph->protocol == IPPROTO_TCP;

	// Replies to inbound sessions, and anything conntrack already tracks.
	if (ct_is_reply(skb))
		return NF_ACCEPT;

	// Anything not TCP/UDP (ICMP included) is not in the allow lists.
	if (!tcp && iph->protocol != IPPROTO_UDP)
		return DEFAULT_RULE;

	if (tcp) {
		src_port = ntohs(tcp_hdr(skb)->source);
		dst_port = ntohs(tcp_hdr(skb)->dest);
		out_list = OUT_PORTS_TCP;
		len_out = sizeof(OUT_PORTS_TCP) / sizeof(OUT_PORTS_TCP[0]);
		in_list_p = IN_PORTS_TCP;
		len_in = sizeof(IN_PORTS_TCP) / sizeof(IN_PORTS_TCP[0]);
	} else {
		src_port = ntohs(udp_hdr(skb)->source);
		dst_port = ntohs(udp_hdr(skb)->dest);
		out_list = OUT_PORTS_UDP;
		len_out = sizeof(OUT_PORTS_UDP) / sizeof(OUT_PORTS_UDP[0]);
		in_list_p = IN_PORTS_UDP;
		len_in = sizeof(IN_PORTS_UDP) / sizeof(IN_PORTS_UDP[0]);
	}

	// Outbound to an allowed service port.
	if (in_list(out_list, len_out, dst_port))
		return NF_ACCEPT;

	// Server side of an inbound session: our answer leaves from a listening
	// port. This mirrors autofirewall's ESTABLISHED,RELATED rule and is what
	// keeps SSH/HTTP usable when conntrack is not attaching on this kernel.
	if (in_list(in_list_p, len_in, src_port))
		return NF_ACCEPT;

	return DEFAULT_RULE;
}

//main INPUT hook func
static unsigned int hook_in(void *priv, struct sk_buff *skb,
			    const struct nf_hook_state *state)
{
	struct iphdr *iph = ip_hdr(skb);
	int src_port, dst_port, len_in;
	const int *in_list_p;
	bool tcp = iph->protocol == IPPROTO_TCP;
	bool is_syn = false;

	// A tracked reply (conntrack available): always allowed back in.
	if (ct_is_reply(skb))
		return NF_ACCEPT;

	// Anything not TCP/UDP (ICMP included) is not in the allow lists.
	if (!tcp && iph->protocol != IPPROTO_UDP)
		return DEFAULT_RULE;

	if (tcp) {
		src_port = ntohs(tcp_hdr(skb)->source);
		dst_port = ntohs(tcp_hdr(skb)->dest);
		is_syn = tcp_hdr(skb)->syn;
		in_list_p = IN_PORTS_TCP;
		len_in = sizeof(IN_PORTS_TCP) / sizeof(IN_PORTS_TCP[0]);
	} else {
		src_port = ntohs(udp_hdr(skb)->source);
		dst_port = ntohs(udp_hdr(skb)->dest);
		in_list_p = IN_PORTS_UDP;
		len_in = sizeof(IN_PORTS_UDP) / sizeof(IN_PORTS_UDP[0]);
	}

	// Inbound to an allowed listening port.
	if (in_list(in_list_p, len_in, dst_port))
		return NF_ACCEPT;

	// Stateless fallback for replies to outbound sessions (see the comment on
	// looks_like_stateless_reply). dst-port matching only: the source port
	// never grants entry on its own.
	if (looks_like_stateless_reply(iph->protocol, src_port, dst_port, is_syn))
		return NF_ACCEPT;

	return DEFAULT_RULE;
}

//set hook prio and chain
static int __init nf_dawg_init(void)
{
	nfho_out.hook = hook_out;
	nfho_out.hooknum = NF_INET_LOCAL_OUT;
	nfho_out.pf = NFPROTO_IPV4;
	//hook prio has to be between conntrack and iptables for this to work
	nfho_out.priority = NF_IP_PRI_CONNTRACK + 1;
	nf_register_net_hook(&init_net, &nfho_out);

	nfho_in.hook = hook_in;
	nfho_in.hooknum = NF_INET_LOCAL_IN;
	nfho_in.pf = NFPROTO_IPV4;
	//hook prio has to be between conntrack and iptables for this to work
	nfho_in.priority = NF_IP_PRI_CONNTRACK + 1;
	nf_register_net_hook(&init_net, &nfho_in);

	// Say which mode we are in: without conntrack this filter is stateless and
	// only lets replies in on ephemeral ports, which is worth knowing during an
	// incident.
	pr_info("dawgfilter: loaded (in tcp{%d} udp{%d}, out tcp{%d} udp{%d}, default DROP)\n",
		(int)(sizeof(IN_PORTS_TCP) / sizeof(IN_PORTS_TCP[0])),
		(int)(sizeof(IN_PORTS_UDP) / sizeof(IN_PORTS_UDP[0])),
		(int)(sizeof(OUT_PORTS_TCP) / sizeof(OUT_PORTS_TCP[0])),
		(int)(sizeof(OUT_PORTS_UDP) / sizeof(OUT_PORTS_UDP[0])));
	return 0;
}

static void __exit nf_dawg_exit(void)
{
	nf_unregister_net_hook(&init_net, &nfho_out);
	nf_unregister_net_hook(&init_net, &nfho_in);
	pr_info("dawgfilter: unloaded\n");
}

module_init(nf_dawg_init);
module_exit(nf_dawg_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("dawgfilter: default-deny IPv4 in/out filter");
