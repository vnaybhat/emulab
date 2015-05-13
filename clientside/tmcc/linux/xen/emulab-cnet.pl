#!/usr/bin/perl -w
#
# Copyright (c) 2000-2014 University of Utah and the Flux Group.
# 
# {{{EMULAB-LICENSE
# 
# This file is part of the Emulab network testbed software.
# 
# This file is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
# 
# This file is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
# License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this file.  If not, see <http://www.gnu.org/licenses/>.
# 
# }}}
#
use strict;
use Getopt::Std;
use English;
use Data::Dumper;
use POSIX qw(setsid);
use Socket;

#
# Invoked by xmcreate script to configure the control network for a vnode.
#
# NOTE: vmid should be an integer ID.
#
sub usage()
{
    print "Usage: emulab-cnet ".
	"vmid host_ip vnode_name vnode_ip (online|offline)\n";
    exit(1);
}

#
# Turn off line buffering on output
#
$| = 1;

# Drag in path stuff so we can find emulab stuff.
BEGIN { require "/etc/emulab/paths.pm"; import emulabpaths; }

#
# Load the OS independent support library. It will load the OS dependent
# library and initialize itself. 
# 
use libsetup;
use libtmcc;
use libutil;
use libtestbed;
use libgenvnode;
use libvnode;

#
# Configure.
#
my $TMCD_PORT	= 7777;
my $SLOTHD_PORT = 8509;
my $EVPROXY_PORT= 16505;
# where all our config files go
my $VMS         = "/var/emulab/vms";
my $VMDIR       = "$VMS/vminfo";
my $IPTABLES	= "/sbin/iptables";
my $ARPING      = "/usr/bin/arping";
my $CAPTURE     = "/usr/local/sbin/capture-nossl";
# For testing.
my $VIFROUTING  = ((-e "$ETCDIR/xenvifrouting") ? 1 : 0);

usage()
    if (@ARGV < 5);

my $vmid      = shift(@ARGV);
my $host_ip   = shift(@ARGV);
my $vnode_id  = shift(@ARGV);
my $vnode_ip  = shift(@ARGV);
my $vnode_mac = shift(@ARGV);

# The caller (xmcreate) puts this into the environment.
my $vif         = $ENV{'vif'};
my $XENBUS_PATH = $ENV{'XENBUS_PATH'};
my $bridge      = `xenstore-read "$XENBUS_PATH/bridge"`;
# Need this for capture.
my $LOGPATH     = "$VMDIR/$vnode_id";

#
# Well, this is interesting; we are called with the XEN store
# gone and so not able to find the bridge. vif-bridge does the same
# thing and just ignores it! So if we cannot get it, default to what
# currently think is the control network bridge, so that vif-bridge
# does not leave a bunch of iptables rules behind. 
#
if ($?) {
    $bridge = "xenbr0";
    # For vif-bridge
    $ENV{"bridge"} = $bridge;
}
chomp($bridge);

#
# We need the domid below; we can figure that out from the XENBUS_PATH.
#
my $domid;
if ($XENBUS_PATH =~ /vif\/(\d*)\//) {
    $domid = $1;
}
else {
    die("Could not determine domid from $XENBUS_PATH\n");
}

my ($bossdomain) = tmccbossinfo();
die("Could not get bossname from tmcc!")
    if (!defined($bossdomain));
if ($bossdomain =~ /^[-\w]+\.(.*)$/) {
    $bossdomain = $1;
}

# We need these IP addresses.
my $boss_ip = `host boss.${bossdomain} | grep 'has address'`;
if ($boss_ip =~ /has address ([0-9\.]*)$/) {
    $boss_ip = $1;
}
my $ops_ip = `host ops.${bossdomain} | grep 'has address'`;
if ($ops_ip =~ /has address ([0-9\.]*)$/) {
    $ops_ip = $1;
}
my $fs_ip = `host fs.${bossdomain} | grep 'has address'`;
if ($fs_ip =~ /has address ([0-9\.]*)$/) {
    $fs_ip = $1;
}
my $PCNET_IP_FILE   = "$BOOTDIR/myip";
my $PCNET_MASK_FILE = "$BOOTDIR/mynetmask";
my $PCNET_GW_FILE   = "$BOOTDIR/routerip";

my $cnet_ip   = `cat $PCNET_IP_FILE`;
my $cnet_mask = `cat $PCNET_MASK_FILE`;
my $cnet_gw   = `cat $PCNET_GW_FILE`;
chomp($cnet_ip);
chomp($cnet_mask);
chomp($cnet_gw);
my $network   = inet_ntoa(inet_aton($cnet_ip) & inet_aton($cnet_mask));

my ($jail_network,$jail_netmask) = findVirtControlNet();
# XXX InstaGeni Rack Hack. Hack until I decide on a better way
my $fs_jailip = "172.17.253.254";

# Each container gets a tmcc proxy running on another port.
# If this changes, look at firewall handling in libvnode_xen.
my $local_tmcd_port = $TMCD_PORT + $vmid;

# Need this too.
my $outer_controlif = `cat $BOOTDIR/controlif`;
chomp($outer_controlif);

#
# We setup a bunch of iptables rules when a container goes online, and
# then clear them when it goes offline.
#
sub Online()
{
    mysystem2("ifconfig $vif txqueuelen 256");

    if ($VIFROUTING) {
	#
	# When using routing instead of bridging, we have to restart
	# dhcp *after* the vif has been created so that dhcpd will
	# start listening on it. 
	#
	if (TBScriptLock("dhcpd", 0, 900) != TBSCRIPTLOCK_OKAY()) {
	    print STDERR "Could not get the dhcpd lock after a long time!\n";
	    return -1;
	}
	restartDHCP();
	TBScriptUnlock();

	#
	# And this clears the arp caches.
	#
	mysystem("$ARPING -c 4 -A -I $bridge $vnode_ip");
    }

    # Prevent dhcp requests from leaving the physical host.
    DoIPtables("-A FORWARD -o $bridge -m pkttype ".
	       "--pkt-type broadcast " .
	       "-m physdev --physdev-in $vif --physdev-is-bridged ".
	       "--physdev-out $outer_controlif -j DROP")
	== 0 or return -1;

    #
    # We turn on antispoofing. In bridge mode, vif-bridge adds a rule
    # to allow outgoing traffic. But vif-route does this wrong, so we
    # do it here. We also need an incoming rule since in route mode,
    # incoming packets go throught the FORWARD table, which is set to
    # DROP for antispoofing.
    #
    # Everything goes through the per vnode INCOMING/OUTGOING tables
    # which are set up in libvnode_xen. If firewalling is not on, then
    # these chains just accept everything. 
    #
    if ($VIFROUTING) {
	DoIPtables("-A FORWARD -i $vif -s $vnode_ip ".
		   "  -m mac --mac-source $vnode_mac -j OUTGOING_${vnode_id}")
	    == 0 or return -1;
	DoIPtables("-A FORWARD -o $vif -d $vnode_ip -j INCOMING_${vnode_id}")
	    == 0 or return -1;

	#
	# Another wrinkle. We have to think about packets coming from
	# the container and addressed to the physical host. Send them
	# through OUTGOING chain for filtering, rather then adding
	# another chain. We make sure there are appropriate rules in
	# the OUTGOING chain to protect the host.
	# 
	DoIPtables("-A INPUT -i $vif -s $vnode_ip ".
		   "  -m mac --mac-source $vnode_mac -j OUTGOING_${vnode_id}")
	    == 0 or return -1;

	#
	# This rule effectively says that if the packet was not filtered 
	# by the INCOMING chain during forwarding, it must be okay to
	# output to the container; we do not want it to go through the
	# dom0 rules.
	#
	DoIPtables("-A OUTPUT -o $vif -j ACCEPT")
	    == 0 or return -1;
    }
    else {
	#
	# Bridge mode. vif-bridge stuck some rules in that we do not
	# want, so insert some new rules ahead of them to capture the
	# packets we want to filter. But we still have to allow the
	# DHCP request packets through.
	#
	DoIPtables("-I FORWARD -m physdev --physdev-is-bridged ".
		   " --physdev-in $vif -s $vnode_ip -j OUTGOING_${vnode_id}")
	    == 0 or return -1;
	    
	DoIPtables("-I FORWARD -m physdev --physdev-is-bridged ".
		   " --physdev-out $vif -j INCOMING_${vnode_id}")
	    == 0 or return -1;

	#
	# Another wrinkle. We have to think about packets coming from
	# the container and addressed to the physical host. Send them
	# through OUTGOING chain for filtering, rather then adding
	# another chain. We make sure there are appropriate rules in
	# the OUTGOING chain to protect the host.
	#
	# XXX: We cannot use the input interface or bridge options, cause
	# if the vnode_ip is unroutable, the packet appears to come from
	# eth0, according to iptables logging. WTF!
	# 
	DoIPtables("-A INPUT -s $vnode_ip ".
		   "  -j OUTGOING_${vnode_id}")
	    == 0 or return -1;

	DoIPtables("-A OUTPUT -d $vnode_ip -j ACCEPT")
	    == 0 or return -1;
    }
    # Start a tmcc proxy (handles both TCP and UDP)
    my $tmccpid = fork();
    if ($tmccpid) {
	# Give child a chance to react.
	sleep(1);
	mysystem2("echo $tmccpid > /var/run/tmccproxy-$vnode_id.pid");
    }
    else {
	POSIX::setsid();
	
	exec("$BINDIR/tmcc.bin -d -t 15 -n $vnode_id ".
	       "  -X $host_ip:$local_tmcd_port -s $boss_ip -p $TMCD_PORT ".
	       "  -o $LOGDIR/tmccproxy.$vnode_id.log");
	die("Failed to exec tmcc proxy"); 
    }

    # Start a capture for the serial console.
    if (-e "$CAPTURE") {
	my $tty = `xenstore-read /local/domain/$domid/console/tty`;
	if (! $?) {
	    chomp($tty);
	    $tty =~ s,\/dev\/,,;

	    # unlink so that we know when capture is ready.
	    my $acl = "$LOGPATH/$vnode_id.acl";
	    unlink($acl)
		if (-e $acl);
	    # Remove old log file before start.
	    my $logfile = "$LOGPATH/$vnode_id.log";
	    unlink($logfile)
		if (-e $logfile);
	    mysystem2("$CAPTURE -C -i -l $LOGPATH $vnode_id $tty");
	    #
	    # We need to tell tmcd about it. But do not hang, use timeout.
	    # Also need to wait for the acl file, since capture is running
	    # in the background. 
	    #
	    if (! $?) {
		for (my $i = 0; $i < 10; $i++) {
		    sleep(1);
		    last
			if (-e $acl && -s $acl);
		}
		if (! (-e $acl && -s $acl)) {
		    print STDERR "$acl does not exist\n";
		}
		else {
		    mysystem2("$BINDIR/tmcc.bin -n $vnode_id -t 5 ".
			      "   -f $acl tiplineinfo");
		}
	    }
	}
    }

    # Reroute tmcd calls to the proxy on the physical host
    DoIPtables("-t nat -A PREROUTING -j DNAT -p tcp ".
	       "  --dport $TMCD_PORT -d $boss_ip -s $vnode_ip ".
	       "  --to-destination $host_ip:$local_tmcd_port")
	== 0 or return -1;

    DoIPtables("-t nat -A PREROUTING -j DNAT -p udp ".
	       "  --dport $TMCD_PORT -d $boss_ip -s $vnode_ip ".
	       "  --to-destination $host_ip:$local_tmcd_port")
	== 0 or return -1;

    # Reroute evproxy to use the local daemon.
    DoIPtables("-t nat -A PREROUTING -j DNAT -p tcp ".
	       "  --dport $EVPROXY_PORT -d $ops_ip -s $vnode_ip ".
	       "  --to-destination $host_ip:$EVPROXY_PORT")
	== 0 or return -1;
    
    #
    # GROSS! source-nat all traffic destined the fs node, to come from the
    # vnode host, so that NFS mounts work. We do this for non-shared nodes.
    # Shared nodes do the mounts normally from inside the guest. The reason
    # for this distinction is that on a shared host, we ask vif-bridge to
    # turn on antispoofing so that the guest cannot use an IP address other
    # then what we assign. On a non-shared node, the user can log into the
    # physical host and pick any IP they want, but as long as the NFS server
    # is exporting only to the physical IP, they won't be able to mount
    # any directories outside their project. The NFS server *does* export
    # filesystems to the guest IPs if the guest is on a shared host.
    # 
    if (!SHAREDHOST()) {
	DoIPtables("-t nat -A POSTROUTING -j SNAT ".
		   "  --to-source $host_ip -s $vnode_ip -d $fs_ip,$fs_jailip ".
		   "  -o $bridge")
	    == 0 or return -1;
    }

    # 
    # If the source is from the vnode, headed to the local control 
    # net, no need for any NAT; just let it through.
    #
    # On a remote node (pcpg) we are not bridged to the control
    # network, and so we route to the control network, and then
    # rely on the SNAT rule below. 
    #
    if (!REMOTEDED()) {
	DoIPtables("-t nat -A POSTROUTING -j ACCEPT " . 
		   " -s $vnode_ip -d $network/$cnet_mask")
	    == 0 or return -1;

	#
	# Do not rewrite multicast (frisbee) traffic. Client throws up.
	# 
	DoIPtables("-t nat -A POSTROUTING -j ACCEPT " . 
		   " -s $vnode_ip -d 224.0.0.0/4")
	    == 0 or return -1;

	#
	# Ditto the apod packet.
	#
	DoIPtables("-t nat -A POSTROUTING -j ACCEPT ".
		   " -s $vnode_ip -m icmp --protocol icmp --icmp-type 6/6")
	    == 0 or return -1;

	#
	# Boss/ops/fs specific rules in case the control network is
	# segmented like it is in Utah.
	#
	DoIPtables("-t nat -A POSTROUTING -j ACCEPT " . 
		   " -s $vnode_ip -d $boss_ip,$ops_ip")
	    == 0 or return -1;
    }

    # 
    # Ditto for the jail network. On a remote node, the only
    # jail network in on our node, and all of them are bridged
    # togther anyway. 
    # 
    DoIPtables("-t nat -A POSTROUTING -j ACCEPT " . 
	       " -s $vnode_ip -d $jail_network/$jail_netmask")
	== 0 or return -1;

    # 
    # Otherwise, setup NAT so that traffic leaving the vnode on its 
    # control net IP, that has been routed out the phys host's
    # control net iface, is NAT'd to the phys host's control
    # net IP, using SNAT.
    # 
    DoIPtables("-t nat -A POSTROUTING ".
	       "-s $vnode_ip -o $outer_controlif ".
	       "-j SNAT --to-source $host_ip")
	== 0 or return -1;
    
    return 0;
}

sub Offline()
{
    # dhcp
    DoIPtables("-D FORWARD -o $bridge -m pkttype ".
	       "--pkt-type broadcast " .
	       "-m physdev --physdev-in $vif --physdev-is-bridged ".
	       "--physdev-out $outer_controlif -j DROP");

    # See above. 
    if ($VIFROUTING) {
	DoIPtables("-D FORWARD -i $vif -s $vnode_ip ".
		   "  -m mac --mac-source $vnode_mac -j OUTGOING_${vnode_id}");
	DoIPtables("-D FORWARD -o $vif -d $vnode_ip -j INCOMING_${vnode_id}");

	DoIPtables("-D INPUT -i $vif -s $vnode_ip ".
		   "  -m mac --mac-source $vnode_mac -j OUTGOING_${vnode_id}");
	DoIPtables("-D OUTPUT -o $vif -j ACCEPT");
	
    }
    else {
	DoIPtables("-D FORWARD -m physdev --physdev-is-bridged ".
		   " --physdev-in $vif -s $vnode_ip -j OUTGOING_${vnode_id}");
	DoIPtables("-D FORWARD -m physdev --physdev-is-bridged ".
		   " --physdev-out $vif -j INCOMING_${vnode_id}");
	DoIPtables("-D INPUT -s $vnode_ip ".
		   "  -j OUTGOING_${vnode_id}");
	DoIPtables("-D OUTPUT -d $vnode_ip -j ACCEPT");
    }

    # tmcc
    # Reroute tmcd calls to the proxy on the physical host
    DoIPtables("-t nat -D PREROUTING -j DNAT -p tcp ".
	       "  --dport $TMCD_PORT -d $boss_ip -s $vnode_ip ".
	       "  --to-destination $host_ip:$local_tmcd_port");
    DoIPtables("-t nat -D PREROUTING -j DNAT -p udp ".
	       "  --dport $TMCD_PORT -d $boss_ip -s $vnode_ip ".
	       "  --to-destination $host_ip:$local_tmcd_port");

    if (-e "/var/run/tmccproxy-$vnode_id.pid") {
	my $pid = `cat /var/run/tmccproxy-$vnode_id.pid`;
	chomp($pid);
	mysystem2("/bin/kill $pid");
    }

    if (-e "$LOGPATH/$vnode_id.pid") {
	my $pid = `cat $LOGPATH/$vnode_id.pid`;
	chomp($pid);
	mysystem2("/bin/kill $pid");
    }

    if (!SHAREDHOST()) {
	DoIPtables("-t nat -D POSTROUTING -j SNAT ".
		   "  --to-source $host_ip -s $vnode_ip -d $fs_ip,$fs_jailip ".
		   "  -o $bridge");
    }

    DoIPtables("-t nat -D POSTROUTING -j ACCEPT " . 
	       " -s $vnode_ip -d $jail_network/$jail_netmask");

    if (!REMOTEDED()) {
	DoIPtables("-t nat -D POSTROUTING -j ACCEPT " . 
		   " -s $vnode_ip -d $network/$cnet_mask");

	DoIPtables("-t nat -D POSTROUTING -j ACCEPT " . 
		   " -s $vnode_ip -d $boss_ip,$ops_ip");
	
	DoIPtables("-t nat -D POSTROUTING -j ACCEPT " . 
		  " -s $vnode_ip -d 224.0.0.0/4");
	
	DoIPtables("-t nat -D POSTROUTING -j ACCEPT ".
		   " -s $vnode_ip -m icmp --protocol icmp --icmp-type 6/6");
    }

    DoIPtables("-t nat -D POSTROUTING ".
	       "-s $vnode_ip -o $outer_controlif -j SNAT --to-source $host_ip");

    # evproxy
    DoIPtables("-t nat -D PREROUTING -j DNAT -p tcp ".
	       "  --dport $EVPROXY_PORT -d $ops_ip -s $vnode_ip ".
	       "  --to-destination $host_ip:$EVPROXY_PORT");

    return 0;
}

if (@ARGV) {
    #
    # Oh jeez, iptables is about the dumbest POS I've ever seen;
    # it fails if you run two at the same time. So we have to
    # serialize the calls. Rather then worry about each call, just
    # take a big lock here. 
    #
    if (TBScriptLock("iptables", 0, 300) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the iptables lock after a long time!\n";
	exit(-1);
    }

    #
    # First run the xen script to do the bridge interface. We do this
    # inside the lock since vif-bridge does some iptables stuff.
    #
    # vif-bridge/vif-route has bugs that cause it to leave iptables
    # rules behind. If we put this stuff into the environment, they
    # will work properly.
    #
    $ENV{"ip"} = $vnode_ip;
    if ($VIFROUTING) {
	$ENV{"netdev"} = "xenbr0";
	$ENV{"gatewaydev"} = "xenbr0";
	mysystem2("/etc/xen/scripts/vif-route-emulab @ARGV");
    }
    else {
	mysystem2("/etc/xen/scripts/vif-bridge @ARGV");
    }
    if ($?) {
	TBScriptUnlock();
	exit(1);
    }
    TBScriptUnlock();
    
    my $rval = 0;
    my $op   = shift(@ARGV);
    if ($op eq "online") {
	$rval = Online();
    }
    elsif ($op eq "offline") {
	$rval = Offline();
    }
    exit($rval);
}
exit(0);
