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
#include "config.h"
#include <linux/netdevice.h>

//get docker net interface
static inline bool is_docker_iface(const struct net_device *dev)
{
	if (!dev){
		return false;
  }
	return strcmp(dev->name, "docker0") == 0 ||
	       strncmp(dev->name, "br-", 3) == 0;
}

//netfilter hooks
static struct nf_hook_ops nfho_in;
static struct nf_hook_ops nfho_out;

//main OUTPUT hook func
static unsigned int hook_out(void *priv, struct sk_buff *skb, const struct nf_hook_state *state){
  if (is_docker_iface(state->out)){
		return NF_ACCEPT;
  }

	//tcp/ip headers
	struct iphdr *iph;
	struct tcphdr *tcph;
	struct udphdr *udph;

	iph = ip_hdr(skb);

	//accept if not TCP
	if (iph->protocol != IPPROTO_TCP && iph->protocol != IPPROTO_UDP){
		pr_info("Unkown Out: %d\n", iph->protocol);
		return DEFAULT_RULE;
	}

  int src_port_tcp;
  int src_port_udp;
  int dst_port_tcp;
  int dst_port_udp;
  int length_in;
  int length_out;
  if(iph->protocol == IPPROTO_TCP){
	  tcph = tcp_hdr(skb);
    src_port_tcp = ntohs(tcph->source);
    dst_port_tcp = ntohs(tcph->dest);
    length_out = sizeof(OUT_PORTS_TCP) / sizeof(OUT_PORTS_TCP[0]);
    length_in = sizeof(IN_PORTS_TCP) / sizeof(IN_PORTS_TCP[0]);
	for(int i = 0; i < length_out; i++){
		if(dst_port_tcp == OUT_PORTS_TCP[i]){
			dst_output(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	for(int i = 0; i < length_in; i++){
		if(src_port_tcp == IN_PORTS_TCP[i]){
			dst_output(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	return DEFAULT_RULE;
  }else if (iph->protocol == IPPROTO_UDP){
    udph = udp_hdr(skb);
    src_port_udp = ntohs(udph->source);
    dst_port_udp = ntohs(udph->dest);
    length_out = sizeof(OUT_PORTS_UDP) / sizeof(OUT_PORTS_UDP[0]);
    length_in = sizeof(IN_PORTS_UDP) / sizeof(IN_PORTS_UDP[0]);

	for(int i = 0; i < length_in; i++){
		if(src_port_udp == IN_PORTS_UDP[i]){
			dst_output(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	for(int i = 0; i < length_out; i++){
		if(dst_port_udp == OUT_PORTS_UDP[i]){
			dst_output(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	return DEFAULT_RULE;
  }

	return DEFAULT_RULE;
}

//main INPUT hook func
static unsigned int hook_in(void *priv, struct sk_buff *skb, const struct nf_hook_state *state){
  if (is_docker_iface(state->in)){
		return NF_ACCEPT;
  }

	//tcp/ip headers
	struct iphdr *iph;
	struct tcphdr *tcph;
	struct udphdr *udph;

	iph = ip_hdr(skb);

	//accept if not TCP
	if (iph->protocol != IPPROTO_TCP && iph->protocol != IPPROTO_UDP){
		pr_info("Unkown In: %d\n", iph->protocol);
		return DEFAULT_RULE;
	}

  int src_port_tcp;
  int src_port_udp;
  int dst_port_tcp;
  int dst_port_udp;
  int length_in; 
  int length_out; 
  if(iph->protocol == IPPROTO_TCP){
	  tcph = tcp_hdr(skb);
    src_port_tcp = ntohs(tcph->source);
    dst_port_tcp = ntohs(tcph->dest);
    length_in = sizeof(IN_PORTS_TCP) / sizeof(IN_PORTS_TCP[0]);
    length_out = sizeof(OUT_PORTS_TCP) / sizeof(OUT_PORTS_TCP[0]);
	for(int i = 0; i < length_in; i++){
		if(dst_port_tcp == IN_PORTS_TCP[i]){
			state->okfn(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	for(int i = 0; i < length_out; i++){
		if(src_port_tcp == OUT_PORTS_TCP[i]){
			state->okfn(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	return DEFAULT_RULE;

  }else if (iph->protocol == IPPROTO_UDP){
    udph = udp_hdr(skb);
    src_port_udp = ntohs(udph->source);
    dst_port_udp = ntohs(udph->dest);
    length_in = sizeof(IN_PORTS_UDP) / sizeof(IN_PORTS_UDP[0]);
    length_out = sizeof(OUT_PORTS_UDP) / sizeof(OUT_PORTS_UDP[0]);
	for(int i = 0; i < length_in; i++){
		if(dst_port_udp == IN_PORTS_UDP[i]){
			state->okfn(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	for(int i = 0; i < length_out; i++){
		if(src_port_udp == OUT_PORTS_UDP[i]){
			state->okfn(state->net, skb->sk, skb);
			return NF_STOLEN;
		}
	}
	return DEFAULT_RULE;

  }

	return DEFAULT_RULE;
}

//set hook prio and chain
static int __init nf_dawg_init(void){
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

	pr_info("dawgfilter: loaded\n");
	return 0;
}

static void __exit nf_dawg_exit(void){
	nf_unregister_net_hook(&init_net, &nfho_out);
	nf_unregister_net_hook(&init_net, &nfho_in);
	pr_info("dawgfilter: unloaded\n");
}

module_init(nf_dawg_init);
module_exit(nf_dawg_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("systemd filterd");
