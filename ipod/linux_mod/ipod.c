/*
 * Copyright (c) 2000-2014 University of Utah and the Flux Group.
 * 
 * {{{EMULAB-LICENSE
 * 
 * This file is part of the Emulab network testbed software.
 * 
 * This file is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at
 * your option) any later version.
 * 
 * This file is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
 * License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this file.  If not, see <http://www.gnu.org/licenses/>.
 * 
 * }}}
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>
#include <linux/kthread.h>
#include <linux/sched.h>
#include <linux/reboot.h>
#include <linux/sysctl.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/skbuff.h>
#include <linux/udp.h>
#include <linux/ip.h>
#include <linux/icmp.h>
#include <net/ip.h>
#include <net/net_namespace.h>
#include <linux/version.h>

#define IPOD_ICMP_TYPE 6
#define IPOD_ICMP_CODE 6

int sysctl_ipod_version = 3;
int sysctl_ipod_enabled = 0;
u32 sysctl_ipod_host = 0xffffffff;
u32 sysctl_ipod_mask = 0xffffffff;
char sysctl_ipod_key[32+1] = { "SETMETOSOMETHINGTHIRTYTWOBYTES!!" };

#define IPOD_CHECK_KEY() \
        (sysctl_ipod_key[0] != 0)
#define IPOD_VALID_KEY(d) \
        (strncmp(sysctl_ipod_key,(char *)(d),sizeof(sysctl_ipod_key) - 1) == 0)

/*
 * Register the simple icmp table in /proc/sys/net/ipv4 .  This way, if
 * somebody else ever adds a net.ipv4.icmp table, like net.ipv6.icmp, we
 * can just add directly to that.
 *
 * Then register the ipod table inside the just-registered icmp table.
 */
static struct ctl_table ipod_table[] = {
    { .procname = "icmp_ipod_version",
      .data = &sysctl_ipod_version,
      .maxlen = sizeof(int),
      .mode = 0444,
      .proc_handler = &proc_dointvec,
    },
    { .procname = "icmp_ipod_enabled",
      .data = &sysctl_ipod_enabled,
      .maxlen = sizeof(int),
      .mode = 0644,
      .proc_handler = &proc_dointvec,
    },
    { .procname = "icmp_ipod_host",
      .data = &sysctl_ipod_host,
      .maxlen = sizeof(u32),
      .mode = 0644,
      .proc_handler = &proc_dointvec,
    },
    { .procname = "icmp_ipod_mask",
      .data = &sysctl_ipod_mask,
      .maxlen = sizeof(u32),
      .mode = 0644,
      .proc_handler = &proc_dointvec,
    },
    { .procname = "icmp_ipod_key",
      .data = &sysctl_ipod_key,
      .maxlen = sizeof(sysctl_ipod_key),
      .mode = 0600,
      .proc_handler = &proc_dostring,
    },
    { 0 },
};

#if LINUX_VERSION_CODE < KERNEL_VERSION(3,5,0)
static struct ctl_path ipod_path[] = {
    {
	.procname = "net",
#if LINUX_VERSION_CODE < KERNEL_VERSION(2,6,33)
	.ctl_name = CTL_NET,
#endif
    },
    {
	.procname = "ipv4",
#if LINUX_VERSION_CODE < KERNEL_VERSION(2,6,33)
	.ctl_name = NET_IPV4,
#endif
    },
    { },
};
#endif

static struct ctl_table_header *ipod_table_header;

static unsigned int ipod_hook_fn(unsigned int hooknum,struct sk_buff *skb,
				 const struct net_device *in,
				 const struct net_device *out,
				 int (*okfn)(struct sk_buff *));

static struct nf_hook_ops ipod_hook_ops = {
    .hook = ipod_hook_fn,
    .owner = THIS_MODULE,
    .hooknum = NF_INET_LOCAL_IN,
    .pf = PF_INET,
    .priority = NF_IP_PRI_FIRST,
};

static unsigned int ipod_hook_fn(unsigned int hooknum,struct sk_buff *skb,
				 const struct net_device *in,
				 const struct net_device *out,
				 int (*okfn)(struct sk_buff *)) {
    struct iphdr *iph;
    struct icmphdr *icmph;
    int doit = 0;
    char *data;

    if (!sysctl_ipod_enabled) 
	return NF_ACCEPT;

    if (!pskb_may_pull(skb,sizeof(*iph) + sizeof(*icmph)))
	return NF_ACCEPT;

    iph = (struct iphdr *)skb_network_header(skb);

    if (iph->protocol != IPPROTO_ICMP)
	return NF_ACCEPT;

    /*
     * icmp_hdr(skb) seems invalid (yet) since the hook is
     * pre-transport; calculate it manually.
     */
    icmph = (struct icmphdr *)((char *)iph + iph->ihl * 4);

    if (!icmph)
	return NF_ACCEPT;

    if (icmph->type != IPOD_ICMP_TYPE || icmph->code != IPOD_ICMP_CODE) 
	return NF_ACCEPT;

    printk(KERN_INFO "IPOD: got type=%d, code=%d, iplen=%d, host=%pI4\n",
	   icmph->type,icmph->code,ntohs(iph->tot_len),&iph->saddr);

    if (sysctl_ipod_host != 0xffffffff &&
	(ntohl(iph->saddr) & sysctl_ipod_mask) == sysctl_ipod_host) {
	/*
	 * Now check the key if enabled.  If packet doesn't contain
	 * enough data or key is otherwise invalid, ignore.
	 */
	if (IPOD_CHECK_KEY()) {
	    data = (char *)((char *)icmph + sizeof(*icmph));
	    if (pskb_may_pull(skb,sizeof(sysctl_ipod_key) - 1)
		&& IPOD_VALID_KEY(data)) 
		doit = 1;
	}
	else 
	    doit = 1;
    }

    if (doit) {
	sysctl_ipod_enabled = 0;
	printk(KERN_CRIT "IPOD: reboot forced by %pI4...\n",&iph->saddr);
	emergency_restart();
	return NF_DROP;
    }
    else {
	printk(KERN_WARNING "IPOD: from %pI4 rejected\n",&iph->saddr);
	return NF_DROP;
    }

    return NF_ACCEPT;
}

static int __init ipod_init_module(void) {
    int rc;

    printk(KERN_INFO "initializing IPOD\n");

    /*
     * Register our sysctls.
     */
#if LINUX_VERSION_CODE < KERNEL_VERSION(3,5,0)
    ipod_table_header = register_net_sysctl_table(&init_net,ipod_path,ipod_table);
#else
    ipod_table_header = register_net_sysctl(&init_net,"net/ipv4",ipod_table);
#endif
    if (!ipod_table_header) {
	printk(KERN_ERR "could not register net.ipv4.icmp[.ipod.*]!\n");
	return -1;
    }

    /*
     * Register our netfilter hook function.
     */
    rc = nf_register_hook(&ipod_hook_ops);
    if (rc) {
	printk(KERN_ERR "netfilter registration failed (%d)!\n",rc);
	unregister_net_sysctl_table(ipod_table_header);
	return -1;
    }

    return 0;
}

static void __exit ipod_cleanup_module(void) {
    printk(KERN_INFO "removing IPOD\n");
    nf_unregister_hook(&ipod_hook_ops);
    unregister_net_sysctl_table(ipod_table_header);
}

module_init(ipod_init_module);
module_exit(ipod_cleanup_module);
MODULE_LICENSE("GPL");
