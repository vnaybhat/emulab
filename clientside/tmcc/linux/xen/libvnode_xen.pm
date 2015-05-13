#!/usr/bin/perl -wT
#
# Copyright (c) 2008-2014 University of Utah and the Flux Group.
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
# Implements the libvnode API for Xen support in Emulab.
#
# Note that there is no distinguished first or last call of this library
# in the current implementation.  Every vnode creation (through mkvnode.pl)
# will invoke all the root* and vnode* functions.  It is up to us to make
# sure that "one time" operations really are executed only once.
#
# TODO:
# + Clear out old, incorrect state in /var/lib/xend.
#   Maybe have to do this when tearing down (killing) vnodes.
#
# + Make more robust, little turds of state still get left around
#   that wreak havoc on reboot.
#
# + Support image loading.
#
package libvnode_xen;
use Exporter;
@ISA    = "Exporter";
@EXPORT = qw( init setDebug rootPreConfig
              rootPreConfigNetwork rootPostConfig
	      vnodeCreate vnodeDestroy vnodeState
	      vnodeBoot vnodePreBoot vnodeHalt vnodeReboot
	      vnodeUnmount
	      vnodePreConfig vnodePreConfigControlNetwork
              vnodePreConfigExpNetwork vnodeConfigResources
              vnodeConfigDevices vnodePostConfig vnodeExec vnodeTearDown VGNAME
	    );
use vars qw($VGNAME);

%ops = ( 'init' => \&init,
         'setDebug' => \&setDebug,
         'rootPreConfig' => \&rootPreConfig,
         'rootPreConfigNetwork' => \&rootPreConfigNetwork,
         'rootPostConfig' => \&rootPostConfig,
         'vnodeCreate' => \&vnodeCreate,
         'vnodeDestroy' => \&vnodeDestroy,
	 'vnodeTearDown' => \&vnodeTearDown,
         'vnodeState' => \&vnodeState,
         'vnodeBoot' => \&vnodeBoot,
         'vnodeHalt' => \&vnodeHalt,
# XXX needs to be implemented
         'vnodeUnmount' => \&vnodeUnmount,
         'vnodeReboot' => \&vnodeReboot,
# XXX needs to be implemented
         'vnodeExec' => \&vnodeExec,
         'vnodePreConfig' => \&vnodePreConfig,
         'vnodePreConfigControlNetwork' => \&vnodePreConfigControlNetwork,
         'vnodePreConfigExpNetwork' => \&vnodePreConfigExpNetwork,
         'vnodeConfigResources' => \&vnodeConfigResources,
         'vnodeConfigDevices' => \&vnodeConfigDevices,
         'vnodePostConfig' => \&vnodePostConfig,
       );


use strict;
use English;
use Data::Dumper;
use Socket;
use File::Basename;
use File::Path;
use File::Copy;
use File::Temp;

# Pull in libvnode
BEGIN { require "/etc/emulab/paths.pm"; import emulabpaths; }
use libutil;
use libgenvnode;
use libvnode;
use libtestbed;
use libsetup;

#
# Turn off line buffering on output
#
$| = 1;

#
# Load the OS independent support library. It will load the OS dependent
# library and initialize itself. 
# 

##
## Standard utilities and files section
##

my $BRCTL = "brctl";
my $IFCONFIG = "/sbin/ifconfig";
my $ETHTOOL = "/sbin/ethtool";
my $ROUTE = "/sbin/route";
my $SYSCTL = "/sbin/sysctl";
my $VLANCONFIG = "/sbin/vconfig";
my $MODPROBE = "/sbin/modprobe";
my $DHCPCONF_FILE = "/etc/dhcpd.conf";
my $NEW_DHCPCONF_FILE = "/etc/dhcp/dhcpd.conf";
my $RESTOREVM	= "$BINDIR/restorevm.pl";
my $LOCALIZEIMG	= "$BINDIR/localize_image";
my $IPTABLES	= "/sbin/iptables";
my $IPBIN	= "/sbin/ip";
my $NETSTAT     = "/bin/netstat";
my $IMAGEZIP    = "/usr/local/bin/imagezip";
my $IMAGEUNZIP  = "/usr/local/bin/imageunzip";
my $IMAGEDUMP   = "/usr/local/bin/imagedump";
my $XM          = "/usr/sbin/xm";
my $debug  = 0;

##
## Randomly chosen convention section
##

# global lock
my $GLOBAL_CONF_LOCK = "xenconf";

# default image to load on logical disks
# Just symlink /boot/vmlinuz-xenU and /boot/initrd-xenU
# to the kernel and ramdisk you want to use by default.
my %defaultImage = (
    'name'      => "emulab-ops-emulab-ops-XEN-STD",
    'kernel'    => "/boot/vmlinuz-xenU",
    'ramdisk'   => "/boot/initrd-xenU",
    'OSVERSION' => "any",
    'PARTOS'    => "Linux",
    'ISPACKAGE' => 0,
    'PART'      => 2,
    'BOOTPART'  => 2,
);

# where all our config files go
my $VMS    = "/var/emulab/vms";
my $VMDIR  = "$VMS/vminfo";
my $XENDIR = "/var/xen";

# Extra space for capture/restore.
my $EXTRAFS = "/capture";

# Extra space for image metadata between reloads.
my $METAFS = "/metadata";

# Extra space for vminfo (/var/emulab/vms) between reloads.
my $INFOFS = "/vminfo";

# Xen LVM volume group name. Accessible outside this file.
$VGNAME = "xen-vg";
# So we can ask this from outside;
sub VGNAME()  { return $VGNAME; }

##
## Indefensible, arbitrary constant section
##

# Maximum vnodes per physical host, used to size memory and disks
my $MAX_VNODES = 32;

# Minimum GB of disk per vnode
my $MIN_GB_DISK = 6;

# Minimum MB of memory per vnode
my $MIN_MB_VNMEM = 64;

# Minimum memory for dom0
my $MIN_MB_DOM0MEM = 256;

# Minimum acceptible size (in GB) of LVM VG for domUs.
my $XEN_MIN_VGSIZE = ($MAX_VNODES * $MIN_GB_DISK);

#
# When loading an Emulab partition image, we use a compressed version of our
# standard MBR layout:
#
# MBR 1 or 2 FreeBSD:
#    P1: 6GB (XEN_LDSIZE) offset at 63, OS goes here
#    P2: 1MB (XEN_EMPTYSIZE), as small as we can make it
#    P3: 1GB (XEN_SWAPSIZE), standard MBR2 swap size
# MBR 1 or 2 Linux:
#    P1: 1MB (XEN_EMPTYSIZE), as small as we can make it
#    P2: 6GB (XEN_LDSIZE) offset at 63, OS goes here
#    P3: 1GB (XEN_SWAPSIZE), standard MBR2 swap size
# MBR 3:
#    P1: 16GB (XEN_LDSIZE_3) offset at 2048, standard OS partition
#    P2: 1MB (XEN_EMPTYSIZE), as small as we can make it
#    P3: 1GB (XEN_SWAPSIZE), standard MBR2 swap size
#
# P4 is sized based on what the user told us.
# Sizes below are in 1K blocks.
#
my $XEN_LDSIZE    =  6152895;
my $XEN_LDSIZE_3  = 16777216;
my $XEN_SWAPSIZE  =  1048576;
my $XEN_EMPTYSIZE =     1024;

# IFBs
my $IFBDB      = "/var/emulab/db/ifbdb";
# Kernel auto-creates only two! Sheesh, why a fixed limit?
my $MAXIFB     = 1024;

# Route tables for tunnels
my $RTDB           = "/var/emulab/db/rtdb";
my $RTTABLES       = "/etc/iproute2/rt_tables";
# Temporary; later kernel version increases this.
my $MAXROUTETTABLE = 255;

# Whether or not to use only unpartitioned (unused) disks to form the Xen VG.
my $LVM_FULLDISKONLY = 0;

# Whether or not to use partitions only when they are big.
my $LVM_ONLYLARGEPARTS = 1;
my $LVM_LARGEPARTPCT = 5;

# LVM snapshots suck.
my $DOSNAP = 0;

# Use openvswitch for gre tunnels.
my $OVSCTL   = "/usr/local/bin/ovs-vsctl";
my $OVSSTART = "/usr/local/share/openvswitch/scripts/ovs-ctl";

my $ISREMOTENODE = REMOTEDED();
my $BRIDGENAME   = "xenbr0";
my $VIFROUTING   = ((-e "$ETCDIR/xenvifrouting") ? 1 : 0);

my $TMCD_PORT	 = 7777;

#
# Information about the running Xen hypervisor
#
my %xeninfo = ();

# Local functions
sub findRoot();
sub copyRoot($$);
sub createRootDisk($);
sub createAuxDisk($$);
sub replace_hacks($);
sub disk_hacks($);
sub configFile($);
sub domain0Memory();
sub totalMemory();
sub hostIP($);
sub createDHCP();
sub addDHCP($$$$);
sub subDHCP($$);
sub restartDHCP();
sub formatDHCP($$$);
sub fixupMac($);
sub createControlNetworkScript($$$);
sub createExpNetworkScript($$$$$$$$);
sub createTunnelScript($$$$$);
sub createExpBridges($$$);
sub destroyExpBridges($$);
sub domainStatus($);
sub domainExists($);
sub addConfig($$$);
sub createXenConfig($$);
sub readXenConfig($);
sub lookupXenConfig($$);
sub getXenInfo();
sub AllocateIFBs($$$);
sub InitializeRouteTable();
sub AllocateRouteTable($);
sub LookupRouteTable($);
sub FreeRouteTable($);
sub downloadOneImage($$);

sub getXenInfo()
{
    open(XM,"$XM info|") 
        or die "getXenInfo: could not run '$XM info': $!";

    while (<XM>) {
	    chomp;
	    /^(\S+)\s*:\s+(.*)$/;
	    $xeninfo{$1} = $2;
    }
    
    close XM;
}

sub init($)
{
    my ($pnode_id,) = @_;

    makeIfaceMaps();
    makeBridgeMaps();

    my $toolstack = `grep TOOLSTACK /etc/default/xen`;
    if ($toolstack =~ /xl$/) {
	$XM = "/usr/sbin/xl";
    }
    getXenInfo();

    #
    # The 4.4 image has to use the openvswitch package instead of building
    # from source since the current release does not support the kernel.
    # And the package is installed in a different place.
    #
    if ($xeninfo{xen_minor} >= 4) {
	$OVSCTL   = "/usr/bin/ovs-vsctl";
	$OVSSTART = "/usr/share/openvswitch/scripts/ovs-ctl";
    }

    return 0;
}

sub setDebug($)
{
    $debug = shift;
    libvnode::setDebug($debug);
    print "libvnode_xen: debug=$debug\n"
	if ($debug);
}

sub ImageLockName($)
{
    my ($imagename) = @_;

    return "xenimage." .
	(defined($imagename) ? $imagename : $defaultImage{'name'});
}

#
# Called on each vnode, but should only be executed once per boot.
# We use a file in /var/run (cleared on reboots) to ensure this.
#
sub rootPreConfig($)
{
    my $bossip = shift;
    #
    # Haven't been called yet, grab the lock and double check that someone
    # didn't do it while we were waiting.
    #
    if (! -e "/var/run/xen.ready") {
	my $locked = TBScriptLock($GLOBAL_CONF_LOCK,
				  TBSCRIPTLOCK_GLOBALWAIT(), 900);
	if ($locked != TBSCRIPTLOCK_OKAY()) {
	    return 0
		if ($locked == TBSCRIPTLOCK_IGNORE());
	    print STDERR "Could not get the xeninit lock after a long time!\n";
	    return -1;
	}
    }
    if (-e "/var/run/xen.ready") {
        TBScriptUnlock();
        return 0;
    }
    
    print "Configuring root vnode context\n";

    #
    # For compatibility with existing (physical host) Emulab images,
    # the physical host provides DHCP info for the vnodes. We manage
    # the dhcpd.conf file here. See below. 
    #
    # Note that we must first add an alias to the control net bridge so
    # that we (the physical host) are in the same subnet as the vnodes,
    # otherwise dhcpd will fail.
    #
    my ($alias_iface, $alias_ip, $alias_mask);

    #
    # Locally, we just need to add the alias to the control interface
    # (which might be a bridge).
    # 
    if (!$ISREMOTENODE) {
	my ($cnet_iface) = findControlNet();

	#
	# We use xen's antispoofing when constructing the guest control net
	# interfaces. This is most useful on a shared host, but no
	# harm in doing it all the time.
	#
	mysystem("$IPTABLES -P FORWARD DROP");
	mysystem("$IPTABLES -F FORWARD");
	# This says to forward traffic across the bridge.
	mysystem("$IPTABLES -A FORWARD ".
		 "-m physdev --physdev-in $cnet_iface -j ACCEPT");
	
	if ($VIFROUTING) {
	    mysystem("echo 1 >/proc/sys/net/ipv4/conf/$cnet_iface/proxy_arp");
	    mysystem("echo 1 >/proc/sys/net/ipv4/ip_forward");
	    # This is for arping -A to work. See emulab-cnet.pl
	    mysystem("echo 1 >/proc/sys/net/ipv4/ip_nonlocal_bind");
	}

	# Set up for metadata server for ec2 support
	print "Setting up redirection for meta server...\n";
	mysystem("$IPBIN addr add 169.254.169.254/32 ".
		 "   scope global dev $cnet_iface");
	mysystem("$IPTABLES -t nat -A PREROUTING -d 169.254.169.254/32 " .
		 "   -p tcp -m tcp --dport 80 -j DNAT ".
		 "   --to-destination ${bossip}:8787");
    }
    else {
	if (!existsBridge($BRIDGENAME)) {
	    if (mysystem2("$BRCTL addbr $BRIDGENAME")) {
		TBScriptUnlock();
		return -1;
	    }
	    #
	    # We do not set the mac address; we want it to take
	    # on the address of the attached vif interfaces so that
	    # arp works. This is quite kludgy of course, but otherwise
	    # the arp comes into the bridge interface and then kernel
	    # drops it. There is a brouter (ebtables) work around
	    # but not worth worrying about. 
	    #
	}
	(undef,$alias_mask,$alias_ip) = findVirtControlNet();
	$alias_iface = $BRIDGENAME;

	if (system("ifconfig $alias_iface | grep -q 'inet addr'")) {
	    print "Creating $alias_iface alias...\n";
	    mysystem("ifconfig $alias_iface $alias_ip netmask $alias_mask");
	}
    }

    # For tunnels
    mysystem("$MODPROBE openvswitch");
    mysystem("$OVSSTART --delete-bridges start");

    # For bandwidth contraints.
    mysystem("$MODPROBE ifb numifbs=$MAXIFB");

    # Create a DB to manage them. 
    my %MDB;
    if (!dbmopen(%MDB, $IFBDB, 0660)) {
	print STDERR "*** Could not create $IFBDB\n";
	TBScriptUnlock();
	return -1;
    }
    for (my $i = 0; $i < $MAXIFB; $i++) {
	$MDB{"$i"} = ""
	    if (!defined($MDB{"$i"}));
    }
    dbmclose(%MDB);
    
    #
    # Ensure that LVM is loaded in the kernel and ready.
    #
    print "Enabling LVM...\n"
	if ($debug);

    # We assume our kernels support this.
    mysystem2("$MODPROBE dm-snapshot");
    if ($?) {
	print STDERR "ERROR: could not load snaphot module!\n";
	TBScriptUnlock();
	return -1;
    }

    #
    # Make sure pieces are at least a GiB.
    #
    my %devs = libvnode::findSpareDisks(1 * 1024);

    #
    # Turn on write caching. Hacky. 
    # XXX note we do not use the returned "path" here as we need to
    # change the setting on all devices, not just the whole disk devices.
    #
    foreach my $dev (keys(%devs)) {
	# only mess with the disks we are going to use
	if (exists($devs{$dev}{"size"}) || $LVM_FULLDISKONLY == 0) {
	    mysystem2("hdparm -W1 /dev/$dev");
	}
    }

    #
    # See if our LVM volume group for VMs exists and create it if not.
    #
    my $vg = `vgs | grep $VGNAME`;
    if ($vg !~ /^\s+${VGNAME}\s/) {
	print "Creating volume group...\n"
	    if ($debug);

	#
	# Total up potential maximum size
	#
	my $maxtotalSize = 0;
	my $sizeThreshold = 0;
	foreach my $dev (keys(%devs)) {
	    if (defined($devs{$dev}{"size"})) {
		$maxtotalSize += $devs{$dev}{"size"};
	    } else {
		foreach my $part (keys(%{$devs{$dev}})) {
		    $maxtotalSize += $devs{$dev}{$part}{"size"};
		}
	    }
	}
	if ($maxtotalSize > 0) {
	    $sizeThreshold = int($maxtotalSize * $LVM_LARGEPARTPCT / 100.0);
	}

	#
	# Find available devices of sufficient size, prepare them,
	# and incorporate them into a volume group.
	#
	my $totalSize = 0;
	my $blockdevs = "";
	foreach my $dev (keys(%devs)) {
	    #
	    # Whole disk is available
	    #
	    if (defined($devs{$dev}{"size"})) {
		$blockdevs .= " " . $devs{$dev}{"path"};
		$totalSize += $devs{$dev}{"size"};
	    }
	    #
	    # Disk contains partitions that are available
	    #
	    else {
		foreach my $part (keys(%{$devs{$dev}})) {
		    my $psize = $devs{$dev}{$part}{"size"};
		    my $ppath = $devs{$dev}{$part}{"path"};

		    #
		    # XXX one way to avoid using the system disk, just ignore
		    # all partition devices. However, in cases where the
		    # remainder of the system disk represents the majority of
		    # the available space (e.g., Utah d710s), this is a bad
		    # idea.
		    #
		    if ($LVM_FULLDISKONLY) {
			print STDERR "WARNING: not using $ppath for LVM (is a partition)\n";
			next;
		    }

		    #
		    # XXX another heurstic to try to weed out the system
		    # disk whenever feasible: if a partition device represents
		    # less than some percentage of the max possible space,
		    # avoid it.
		    #
		    if ($LVM_ONLYLARGEPARTS && $psize < $sizeThreshold) {
			print STDERR "WARNING: not using $ppath for LVM (too small)\n";
			next;
		    }

		    #
		    # It ran the gauntlet of feeble filters, use it!
		    #
		    $blockdevs .= " " . $ppath;
		    $totalSize += $psize;
		}
	    }
	}
	if ($blockdevs eq '') {
	    print STDERR "ERROR: findSpareDisks found no disks for LVM!\n";
	    TBScriptUnlock();
	    return -1;
	}
		    
	mysystem("pvcreate $blockdevs");
	mysystem("vgcreate $VGNAME $blockdevs");

	my $size = lvmVGSize($VGNAME);
	if ($size < $XEN_MIN_VGSIZE) {
	    print STDERR "WARNING: physical disks not big enough to support".
		" $MAX_VNODES VMs ($size < $XEN_MIN_VGSIZE)\n";
	}
    }

    #
    # Make sure our volumes are active -- they seem to become inactive
    # across reboots
    #
    mysystem("vgchange -a y $VGNAME");

    print "Creating dhcp.conf skeleton...\n"
        if ($debug);
    createDHCP();

    print "Creating scratch FS ...\n";
    if (createExtraFS($EXTRAFS, $VGNAME, "25G")) {
	TBScriptUnlock();
	return -1;
    }
    print "Creating image metadata FS ...\n";
    if (createExtraFS($METAFS, $VGNAME, "1G")) {
	TBScriptUnlock();
	return -1;
    }
    print "Creating container info FS ...\n";
    if (createExtraFS($INFOFS, $VGNAME, "3G")) {
	TBScriptUnlock();
	return -1;
    }
    if (! -l $VMS) {
	#
	# We need this stuff to be sticky across reloads, so move it
	# into an lvm. If we lose the lvm, well then we are screwed.
	#
	my @files = glob("$VMS/*");
	foreach my $file (@files) {
	    my $base = basename($file);
	    mysystem("/bin/mv $file $INFOFS")
		if (! -e "$INFOFS/$base");
	}
	mysystem("/bin/rm -rf $VMS");
	mysystem("/bin/ln -s $INFOFS $VMS");
    }

    if (InitializeRouteTables()) {
	print STDERR "*** Could not initialize routing table DB\n";
	TBScriptUnlock();
	return -1;
    }

    #
    # Need these to avoid overflowing the NAT tables.
    #
    mysystem2("$MODPROBE nf_conntrack");
    if ($?) {
	print STDERR "ERROR: could not load nf_conntrack module!\n";
	TBScriptUnlock();
	return -1;
    }
    mysystem2("$SYSCTL -w ".
	     "  net.netfilter.nf_conntrack_generic_timeout=120");
    mysystem2("$SYSCTL -w ".
	     "  net.netfilter.nf_conntrack_tcp_timeout_established=54000");
    mysystem2("$SYSCTL -w ".
	     "  net.netfilter.nf_conntrack_max=131071");
    mysystem2("echo 16384 > /sys/module/nf_conntrack/parameters/hashsize");
 
    # These might fail on new kernels.  
    mysystem2("$SYSCTL -w ".
	      " net.ipv4.netfilter.ip_conntrack_generic_timeout=120");
    mysystem2("$SYSCTL -w ".
	      " net.ipv4.netfilter.ip_conntrack_tcp_timeout_established=54000");

    mysystem("touch /var/run/xen.ready");
    TBScriptUnlock();
    return 0;
}

sub rootPreConfigNetwork($$$$)
{
    my ($vnode_id, undef, $vnconfig, $private) = @_;
    my @node_ifs = @{ $vnconfig->{'ifconfig'} };
    my @node_lds = @{ $vnconfig->{'ldconfig'} };

    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 900) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global lock after a long time!\n";
	return -1;
    }

    createDHCP()
	if (! -e $DHCPCONF_FILE && ! -e $NEW_DHCPCONF_FILE);

    if (!$ISREMOTENODE) {
	my ($cnet_iface) = findControlNet();
	my ($alias_ip,$alias_mask) = domain0ControlNet();
	my $alias_iface = "$cnet_iface:1";

	if (system("ifconfig $alias_iface | grep -q 'inet addr'")) {
	    print "Creating $alias_iface alias...\n";
	    mysystem("ifconfig $alias_iface $alias_ip netmask $alias_mask");
	}
    }

    #
    # If we blocked, it would be because vnodes have come or gone,
    # so we need to rebuild the maps.
    #
    makeIfaceMaps();
    makeBridgeMaps();

    TBScriptUnlock();
    return 0;
bad:
    TBScriptUnlock();
    return -1;
}

sub rootPostConfig($)
{
    return 0;
}

#
# Create the basic context for the VM and give it a unique ID for identifying
# "internal" state.  If $raref is set, then we are in a RELOAD state machine
# and need to walk the appropriate states.
#
sub vnodeCreate($$$$)
{
    my ($vnode_id, undef, $vnconfig, $private) = @_;
    my $attributes = $vnconfig->{'attributes'};
    my $imagename = $vnconfig->{'image'};
    my $raref = $vnconfig->{'reloadinfo'};
    my $vninfo = $private;
    my %image = %defaultImage;
    my $imagemetadata;
    my $lvname;
    my $inreload = 0;

    my $vmid;
    if ($vnode_id =~ /^[-\w]+\-(\d+)$/) {
	$vmid = $1;
    }
    else {
	fatal("xen_vnodeCreate: bad vnode_id $vnode_id!");
    }
    $vninfo->{'vmid'} = $vmid;

    #
    # 
    #
    if (CreateVnodeLock() != 0) {
	fatal("CreateVnodeLock()");
    }

    #
    # We need to lock while messing with the image. But we can use
    # shared lock so that others can proceed in parallel. We will have
    # to promote to an exclusive lock if the image has to be changed.
    #
    my $imagelockname = ImageLockName($imagename);
    if (TBScriptLock($imagelockname, TBSCRIPTLOCK_SHAREDLOCK(), 1800)
	!= TBSCRIPTLOCK_OKAY()) {
	fatal("Could not get $imagelockname lock after a long time!");
    }

    #
    # No image specified, use a default based on the dom0 OS.
    #
    if (!defined($imagename)) {
	$lvname = $image{'name'};
	
	#
	# Setup the default image now.
	# XXX right now this is a hack where we just copy the dom0
	# filesystem and clone (snapshot) that.
	#
	$imagename = $defaultImage{'name'};
	print STDERR "xen_vnodeCreate: ".
	    "no image specified, using default ('$imagename')\n";

	# Okay to fail if image does not exist yet.
	LoadImageMetadata($imagename, \$imagemetadata);

	$lvname = "image+" . $imagename;
	if (!findLVMLogicalVolume($lvname) &&
	    !defined($imagemetadata)) {
	    
	    #
	    # Need an exclusive lock for this.
	    #
	    TBScriptUnlock();	    
	    if (TBScriptLock($imagelockname, undef, 1800)
		!= TBSCRIPTLOCK_OKAY()) {
		fatal("Could not get $imagelockname write lock ".
		      "after a long time!");
	    }
	    # And now check again in case someone else snuck in.
	    if (!findLVMLogicalVolume($lvname) && createRootDisk($imagename)) {
		TBScriptUnlock();
		fatal("xen_vnodeCreate: ".
		      "cannot find create root disk for default image");
	    }
	    # And back to a shared lock.
	    TBScriptUnlock();
	    if (TBScriptLock($imagelockname, TBSCRIPTLOCK_SHAREDLOCK(), 1800)
		!= TBSCRIPTLOCK_OKAY()) {
		fatal("Could not get $imagelockname lock back ".
		      "after a long time!");
	    }
	    $imagemetadata = undef;
	}
    }
    elsif (!defined($raref)) {
	#
	# Boot existing image. The base volume has to exist, since we do
	# not have any reload info to get it.
	#
	$lvname = "image+" . $imagename;
	if (!findLVMLogicalVolume($lvname)) {
	    TBScriptUnlock();
	    fatal("xen_vnodeCreate: ".
		  "cannot find logical volume for $lvname, and no reload info");
	}
    }
    else {
	$lvname = "image+" . $imagename;
	$inreload = 1;

	print STDERR "xen_vnodeCreate: loading image '$imagename'\n";

	# Tell stated we are getting ready for a reload
	libutil::setState("RELOADSETUP");

	#
	# Immediately drop into RELOADING before calling createImageDisk as
	# that is the place where any image will be downloaded from the image
	# server and we want that download to take place in the longer timeout
	# period afforded by the RELOADING state.
	#
	libutil::setState("RELOADING");

	if (createImageDisk($imagename, $vnode_id, $raref)) {
	    TBScriptUnlock();
	    fatal("xen_vnodeCreate: ".
		  "cannot create logical volume for $imagename");
	}
    }

    #
    # Load this from disk.
    #
    if (!defined($imagemetadata)) {
	if (LoadImageMetadata($imagename, \$imagemetadata)) {
	    TBScriptUnlock();
	    fatal("xen_vnodeCreate: ".
		  "cannot load image metadata for $imagename");
	}
    }

    #
    # See if the image is really a package.
    #
    if (exists($imagemetadata->{'ISPACKAGE'}) && $imagemetadata->{'ISPACKAGE'}){
	my $imagepath = lvmVolumePath($lvname);
	# In case of reboot.
	mysystem("mkdir -p /mnt/$imagename")
	    if (! -e "/mnt/$imagename");
	mysystem("mount $imagepath /mnt/$imagename")
	    if (! -e "/mnt/$imagename/.mounted");

	mysystem2("$RESTOREVM -t $VMDIR/$vnode_id $vnode_id /mnt/$imagename");
	if ($?) {
	    TBScriptUnlock();
	    fatal("xen_vnodeCreate: ".
		  "cannot restore logical volumes from $imagename");
	}
	if ($inreload) {
	    libutil::setState("RELOADDONE");
	    sleep(4);
	}
	
	#
	# All of the lvms are created and a new xm.conf created.
	# Read that xm.conf in so we can figure out what lvms we
	# need to delete later (recreate the disks array). 
	#
	my $conf = configFile($vnode_id);
	my $aref = readXenConfig($conf);
	if (!$aref) {
	    TBScriptUnlock();
	    fatal("xen_vnodeCreate: ".
		  "Cannot read restored config file from $conf");
	}
	$vninfo->{'cffile'} = $aref;
	
	my $disks = parseXenDiskInfo($vnode_id, $aref);
	if (!defined($disks)) {
	    TBScriptUnlock();
	    fatal("xen_vnodeCreate: Could not restore disk info from $conf");
	}
	$private->{'disks'} = $disks;
	#
	# We want to support extra disk space on this path, but we cannot
	# just stick into the 4th partition like we do below, but have to
	# add an extra disk instead. But to do that we have to look at the
	# disks we just parsed and see what the highest lettered drive is.
	#
	if (exists($attributes->{'XEN_EXTRAFS'})) {
	    my $dsize   = $attributes->{'XEN_EXTRAFS'};
	    my $auxchar = ord('c');
	    my @stanzas = ();
	    
	    my $dpre = "xvd";
	    foreach my $disk (keys(%{$private->{'disks'}})) {
		my ($lvname,$vndisk,$vdisk) = @{$private->{'disks'}->{$disk}};
		if ($vdisk =~ /^(sd)(\w)$/ || $vdisk =~ /^(xvd)(\w)$/ ||
		    $vdisk =~ /^(hd)(\w)$/) {
		    $dpre = $1;
		    $auxchar = ord($2)
			if (ord($2) > $auxchar);
		}
		# Generate a new set of stanzas. see below.
		push(@stanzas, "'phy:$vndisk,$vdisk,w'");
	    }
	    my $vdisk = $dpre .	chr($auxchar);
	    my $auxlvname = "${vnode_id}.${vdisk}";
	    
	    if (!findLVMLogicalVolume($auxlvname)) {
		if (createAuxDisk($auxlvname, $dsize . "G")) {
		    fatal("libvnode_xen: could not create aux disk: $vdisk");
		}
	    }
	    my $vndisk = lvmVolumePath($auxlvname);
	    my $stanza = "'phy:$vndisk,$vdisk,w'";
	    $private->{'disks'}->{$auxlvname} = [$auxlvname, $vndisk, $vdisk];
	    push(@stanzas, $stanza);

	    #
	    # Replace the existing line in the conf file. 
	    #
	    addConfig($vninfo, "disk = [" . join(",", @stanzas) . "]", 2);

	    # Cause we have no idea.
	    $private->{'os'} = "other";
	}
	
	TBScriptUnlock();
	CreateVnodeUnlock();
	goto done;
    }

    #
    # We get the OS and version from loadinfo.
    #
    my $vdiskprefix = "sd";	# yes, this is right for FBSD too
    my $ishvm = 0;
    my $os;
    
    if ($imagemetadata->{'PARTOS'} =~ /freebsd/i) {
	$os = "FreeBSD";

	# XXX we assume that all 10.0 and above will be PVHVM
	if ($imagemetadata->{'OSVERSION'} >= 10) {
	    $ishvm = 1;
	}
    }
    else {
	$os = "Linux";

	if ($xeninfo{xen_major} >= 4) {
	    $vdiskprefix = "xvd";
	}
    }
    $private->{'os'} = $os;
    $private->{'ishvm'} = $ishvm;

    # All of the disk stanzas for the config file.
    my @alldisks = ();
    # Cache the config file, but will read it later.
    $private->{'disks'} = {};

    #
    # The root disk.
    #
    my $rootvndisk = lvmVolumePath($vnode_id);

    #
    # Since we may have (re)loaded a new image for this vnode, check
    # and make sure the vnode snapshot disk is associated with the
    # correct image.  Otherwise destroy the current vnode LVM so it
    # will get correctly associated below.
    #
    if (findLVMLogicalVolume($vnode_id)) {
	my $olvname = findLVMOrigin($vnode_id);
	if (defined($raref) ||
	    ($olvname ne "" && $olvname ne $lvname)) {
	    RunWithLock("kpartx", "kpartx -dv $rootvndisk");
	    if (mysystem2("lvremove -f $VGNAME/$vnode_id")) {
		TBScriptUnlock();
		fatal("xen_vnodeCreate: ".
		      "could not destroy old disk for $vnode_id");
	    }
	}
    }

    #
    # Figure out what slice the image is going in. It might be a whole
    # disk image though, so need to figure out what partition to boot.
    # Otherwise we force single slice images into its partition, and
    # put a swap partition after it. Lastly, if an extra disk partition
    # was requested, put that after the swap partition. This will allow
    # the user to take a whole disk image snapshot and load it on a physical
    # node later. 
    #
    print Dumper($imagemetadata);
    my $loadslice  = $imagemetadata->{'PART'};
    my $bootslice  = $loadslice;
    my $rootvdisk  = "${vdiskprefix}a";
    my $rootstanza = "phy:$rootvndisk,${vdiskprefix}a,w";
    push(@alldisks, "'$rootstanza'");

    #
    # Create the snapshot LVM.
    #
    if (!findLVMLogicalVolume($vnode_id)) {
	#
	# Need to create a new disk for the container. But lets see
	# if we have a disk cached. We still have the imagelock at
	# this point.
	#
	# Ick, this has to be done under an exclusive lock, but we
	# are currently running under a shared lock. We cannot drop
	# the shared lock though (and flock does promotion by drop
	# and relock). So, need to take another lock if we find
	# cached files.
	#
	if (my (@files) = glob("/dev/$VGNAME/_C_${imagename}_*")) {
	    #
	    # Grab the first file and rename it. It becomes ours.
	    # Then drop the lock.
	    #
	    my $file = $files[0];
	    if (mysystem2("lvrename $file $rootvndisk")) {
		TBScriptUnlock();
		fatal("libvnode_xen: could not rename cache file");
	    }
	}
	else {
	    my $extrafs = 
		(exists($attributes->{'XEN_EXTRAFS'}) ?
		 $attributes->{'XEN_EXTRAFS'} : undef);
		 
	    if (CreatePrimaryDisk($lvname,
				  $imagemetadata, $vnode_id, $extrafs)) {
		TBScriptUnlock();
		fatal("libvnode_xen: could not clone $lvname");
	    }
	    if ($inreload) {
		libutil::setState("RELOADDONE");
		sleep(5);
		
		#
		# We have to ask what partition to boot, since the
		# that info does not come across in the loadinfo, and
		# we cannot ask until RELOADDONE is sent. 
		#
		if ($loadslice == 0 && !exists($imagemetadata->{'BOOTPART'})) {
		    my @tmp;

		    if (getbootwhat(\@tmp) || !scalar(@tmp) ||
			!exists($tmp[0]->{"WHAT"}) ||
			$tmp[0]->{"WHAT"} !~ /^\d*$/) {
			print STDERR Dumper(\@tmp);
			TBScriptUnlock();
			fatal("libvnode_xen: could not get bootwhat info");
		    }
		    $bootslice = $tmp[0]->{"WHAT"};
		    #
		    # Store it back into the metadata for next time.
		    #
		    $imagemetadata->{'BOOTPART'} = $bootslice;
		    StoreImageMetadata($imagename, $imagemetadata);
		}
	    }
	}
	if ($loadslice == 0) {
	    $bootslice = $imagemetadata->{'BOOTPART'};
	}
	#
	# Need to create mapper entries so we can mount the
	# boot filesystem later, for slicefix.
	#
	if (RunWithLock("kpartx", "kpartx -av $rootvndisk")) {
	    TBScriptUnlock();
	    fatal("libvnode_xen: could not add /dev/mapper entries");
	}
	# Hmm, some kind of kpartx race ...
	sleep(2);
    }
    # Need to tell slicefix where to find the root partition.
    # Naming convention is a pain.
    my $devname = "$VGNAME/${vnode_id}p$bootslice";
    $devname =~ s/\-/\-\-/g;
    $devname =~ s/\//\-/g;
    $private->{'rootpartition'} = "/dev/mapper/$devname";
    $rootvdisk .= "${bootslice}";
    
    # Mark the lvm as created, for cleanup on error.
    $private->{'disks'}->{$vnode_id} = [$vnode_id, $rootvndisk, $rootvndisk];

    #
    # The rest of this can proceed in parallel with other VMs.
    #
    TBScriptUnlock();
    CreateVnodeUnlock();
    
    #
    # Extract kernel and ramdisk.
    #
    if ($os eq "FreeBSD") {
	my $kernel =
	    ExtractKernelFromFreeBSDImage($vnode_id,
					  $private->{'rootpartition'},
					  "$VMDIR/$vnode_id");
	if (!defined($kernel)) {
	    if ($imagemetadata->{'OSVERSION'} >= 10) {
		# we only support HVM for 10+ kernels
		$kernel = "NO-PV-KERNELS";
	    } elsif ($imagemetadata->{'OSVERSION'} >= 9) {
		$kernel = "/boot/freebsd9/kernel";
	    }
	    elsif ($imagemetadata->{'OSVERSION'} >= 8) {
		$kernel = "/boot/freebsd8/kernel";
	    }
	    else {
		$kernel = "/boot/freebsd/kernel";
	    }
	    if (! -e $kernel) {
		fatal("libvnode_xen: ".
		      "no FreeBSD kernel for '$imagename' on $vnode_id");
	    }
	}
	if ($ishvm) {
	    undef $image{'kernel'};
	} else {
	    $image{'kernel'} = $kernel;
	}
	undef $image{'ramdisk'};
    }
    else {
	if ($imagemetadata->{'PARTOS'} =~ /fedora/i &&
	    $imagemetadata->{'OSVERSION'} >= 8 &&
	    $imagemetadata->{'OSVERSION'} < 9) {
	    $image{'kernel'}  = "/boot/fedora8/vmlinuz-xenU";
	    $image{'ramdisk'} = "/boot/fedora8/initrd-xenU";
	}
	elsif ($imagename ne $defaultImage{'name'}) {
	    #
	    # See if we can dig the kernel out from the image.
	    #
	    my ($kernel,$ramdisk) =
		ExtractKernelFromLinuxImage($vnode_id, "$VMDIR/$vnode_id");

	    if (defined($kernel)) {
		my $usebootloader = 1;
		
		#
		# If this is an Ubuntu ramdisk, we have to make sure it
		# will boot as a XEN guest, by changing the ramdisk. YUCK!
		#
		if ($imagemetadata->{'PARTOS'} =~ /ubuntu/i ||
		    $imagename =~ /ubuntu/i ||
		    system("strings $kernel | grep -q -i ubuntu") == 0) {
		    my $ramres = FixRamFs($vnode_id, $ramdisk);
		    if ($ramres < 0) {
			fatal("xen_vnodeCreate: Failed to fix ramdisk");
		    }
		    elsif ($ramres == 0) {
			# Ramfs needed to be changed, so cannot use pygrub.
			$usebootloader = 0;
		    }
		}
		if ($usebootloader) {
		    $image{'bootloader'}  = 'pygrub';
		}
		else {
		    $image{'kernel'}  = $kernel;
		    $image{'ramdisk'} = $ramdisk;
		}
	    }
	    # Use the booted kernel. Works sometimes. 
	}
    }

    my $auxchar  = ord('b');
    #
    # Create a swap disk.
    #
    if (0 && $os eq "FreeBSD") {
	my $auxlvname = "${vnode_id}.swap";
	my $vndisk = lvmVolumePath($auxlvname);
	
	if (!findLVMLogicalVolume($auxlvname)) {
	    if (createAuxDisk($auxlvname, "2G")) {
		fatal("libvnode_xen: could not create swap disk");
	    }
	    #
	    # Mark it as a linux swap partition. 
	    #
	    if (mysystem2("echo ',,S' | sfdisk $vndisk -N0")) {
		fatal("libvnode_xen: could not partition swap disk");
	    }
	}
	my $vdisk  = $vdiskprefix . chr($auxchar++);
	my $stanza = "phy:$vndisk,$vdisk,w";

	$private->{'disks'}->{$auxlvname} = [$auxlvname, $vndisk, $vdisk];
	push(@alldisks, "'$stanza'");
    }

    #
    # Create aux disks.
    #
    if (exists($attributes->{'XEN_EXTRADISKS'})) {
	my @list = split(",", $attributes->{'XEN_EXTRADISKS'});
	foreach my $disk (@list) {
	    my ($name,$size) = split(":", $disk);

	    my $auxlvname = "${vnode_id}.${name}";
	    if (!findLVMLogicalVolume($auxlvname)) {
		if (createAuxDisk($auxlvname, $size)) {
		    fatal("libvnode_xen: could not create aux disk: $name");
		}
	    }
	    my $vndisk = lvmVolumePath($auxlvname);
	    my $vdisk  = $vdiskprefix . chr($auxchar++);
	    my $stanza = "phy:$vndisk,$vdisk,w";

	    $private->{'disks'}->{$auxlvname} = [$auxlvname, $vndisk, $vdisk];
	    push(@alldisks, "'$stanza'");
	}
    }
    print "All disks: @alldisks\n" if ($debug);

    #
    # Create the config file and fill in the disk/filesystem related info.
    # Since we don't want to leave a partial config file in the event of
    # a failure down the road, we just accumulate the config info in a string
    # and write it out right before we boot.
    #
    # BSD PV stuff inspired by:
    # http://wiki.freebsd.org/AdrianChadd/XenHackery
    # BSD PVHVM stuff inspired by:
    # http://wiki.xen.org/wiki/Testing_FreeBSD_PVHVM
    #
    $vninfo->{'cffile'} = [];

    my $kernel = $image{'kernel'};
    my $ramdisk = $image{'ramdisk'};
    my $bootloader = $image{'bootloader'};

    addConfig($vninfo, "# Xen configuration script for $os vnode $vnode_id", 2);
    addConfig($vninfo, "name = '$vnode_id'", 2);
    if (defined($bootloader)) {
	addConfig($vninfo, "bootloader = '$bootloader'", 2);
    }
    else {
	addConfig($vninfo, "kernel = '$kernel'", 2)
	    if (defined($kernel));
	addConfig($vninfo, "ramdisk = '$ramdisk'", 2)
	    if (defined($ramdisk));
    }
    addConfig($vninfo, "disk = [" . join(",", @alldisks) . "]", 2);

    if ($os eq "FreeBSD") {
	if ($ishvm) {
	    addConfig($vninfo, "extra = 'boot_verbose=1'", 2);

	    addConfig($vninfo, "builder='hvm'", 2);
	    addConfig($vninfo, "xen_platform_pci=1", 2);
	    addConfig($vninfo, "boot='c'", 2);
	    addConfig($vninfo, "serial='pty'", 2);
	    addConfig($vninfo, "apic=1", 2);
	    addConfig($vninfo, "acpi=1", 2);
	    addConfig($vninfo, "pae=1", 2);
	    # XXX wont start without vnc=1
	    addConfig($vninfo, "vnc=1", 2);
	    addConfig($vninfo, "sdl=0", 2);
	    addConfig($vninfo, "stdvga=0", 2);
	} else {
	    addConfig($vninfo, "extra = 'boot_verbose=1" .
		      ",vfs.root.mountfrom=ufs:/dev/da0s1a".
		      ",kern.bootfile=/boot/kernel/kernel'", 2);
	}
    } else {
	addConfig($vninfo, "root = '/dev/$rootvdisk ro'", 2);
	addConfig($vninfo, "extra = ".
		  "        'console=hvc0 xencons=tty apparmor=0 selinux=0'", 2);
    }
  done:

    #
    # We allow the server to tell us how many VCPUs to allocate to the
    # guest. 
    #
    if (exists($attributes->{'VM_VCPUS'}) && $attributes->{'VM_VCPUS'} > 1) {
	addConfig($vninfo, "vcpus = " . $attributes->{'VM_VCPUS'}, 2);
    }

    #
    # VNC console setup. Not very useful since on shared nodes there
    # is no local account for the users to log in and connect to
    # the port, and we definitely do not want export it since there
    # is no password and no encryption. So, leave out for now.
    #
    if (0) {
	addConfig($vninfo, "vfb = ['vnc=1,vncdisplay=$vmid,vncunused=0']", 2);
	addConfig($vninfo,
		  "device_model_version = 'qemu-xen-traditional'", 2);
	addConfig($vninfo,
		  "device_model_override = '/usr/lib/xen-4.3/bin/qemu-dm'",2);
    }
    
    #
    # Finish off the state transitions as necessary.
    #
    if ($inreload) {
	libutil::setState("SHUTDOWN");
    }
    return $vmid;
}

#
# The logical disk has been created.
# Here we just mount it and invoke the callback.
#
# XXX note that the callback only works when we can mount the VM OS's
# filesystems!  We know how to do this for Linux and FreeBSD.
#
sub vnodePreConfig($$$$$){
    my ($vnode_id, $vmid, $vnconfig, $private, $callback) = @_;
    my $vninfo = $private;
    my $retval = 0;
    my $fixups = 0;

    #
    # XXX vnodeCreate is not called when a vnode was halted or is rebooting.
    # In that case, we read in any existing config file and restore the
    # disk info. 
    #
    if (!exists($vninfo->{'cffile'})) {
	my $aref = readXenConfig(configFile($vnode_id));
	if (!$aref) {
	    fatal("vnodePreConfig: no Xen config for $vnode_id!");
	}
	$vninfo->{'cffile'} = $aref;

	#
	# And, we need to recover the disk info from the config file.
	#
	my $disks = parseXenDiskInfo($vnode_id, $aref);
	if (!defined($disks)) {
	    fatal("vnodePreConfig: Could not restore disk info from config");
	}
	$private->{'disks'} = $disks;
    }
    if (!exists($vninfo->{'os'})) {
	#
	# Ick, we lost this info during reboot cause we start with a
	# fresh private info. Need to ponder this. But anyway, this is
	# a temp hack so we can apply some fixups to all containers.
	#
	# Make sure its a Linux partition. If not, ignore it.
	#
	my $devname = "$VGNAME/${vnode_id}";
	$devname =~ s/\-/\-\-/g;
	$devname =~ s/\//\-/g;
	my $devfile = "/dev/mapper/$devname";
	print STDERR "$devfile\n";
	return 0
	    if (! -e $devfile);
	
	my $stype = `sfdisk $devfile -c 2`;
	chomp($stype);
	return 0
	    if ($? || $stype == 0);

	print STDERR "stype $stype\n";
	
	
	$fixups = 1;
	$vninfo->{'os'} = "Linux";
	$private->{'rootpartition'} = "${devfile}p2";
    }
    
    #
    # XXX can only do the rest for nodes whose files systems we can mount.
    #
    return 0
	if (! ($vninfo->{'os'} eq "Linux" || $vninfo->{'os'} eq "FreeBSD"));
    
    mkpath(["/mnt/xen/$vnode_id"]);
    my $dev = $private->{'rootpartition'};
    my $vnoderoot = "/mnt/xen/$vnode_id";

    #
    # On a reboot, we might not have the mapper entries ...
    #
    if (! -e $dev) {
	my $rootvndisk = lvmVolumePath($vnode_id);
	if (RunWithLock("kpartx", "kpartx -av $rootvndisk")) {
	    fatal("libvnode_xen: could not add /dev/mapper entries");
	}
    }

    #
    # We rely on the UFS module (with write support compiled in) to
    # deal with FBSD filesystems. 
    #
    if ($vninfo->{'os'} eq "FreeBSD") {
	mysystem2("mount -t ufs -o ufstype=44bsd $dev $vnoderoot");
	if ($?) {
	    # try UFS2
	    mysystem("mount -t ufs -o ufstype=ufs2 $dev $vnoderoot");
	}
    }
    else {
	mysystem("mount $dev $vnoderoot");
    }

    #
    # Deal with fixups and return
    #
    if ($fixups) {
	mysystem2("/bin/cp -fp /etc/ntp.conf $vnoderoot/etc/ntp.conf");
	goto done;
    }

    # XXX We need to get rid of this or get it from tmcd!
    if (! -e "$vnoderoot/etc/emulab/genvmtype") {
	mysystem2("echo 'xen' > $vnoderoot/etc/emulab/genvmtype");
	goto bad
	    if ($?);
    }

    # Use the physical host pubsub daemon
    my (undef, $ctrlip) = findControlNet();
    if (!$ctrlip || $ctrlip !~ /^(\d+\.\d+\.\d+\.\d+)$/) {
	if ($?) {
	    print STDERR
		"vnodePreConfig: could not get control net IP for $vnode_id";
	    goto bad;
	}
    }

    if ($vninfo->{'os'} ne "FreeBSD") {
	# Should be handled in libsetup.pm, but just in case
	if (! -e "$vnoderoot/var/emulab/boot/localevserver" ) {
	    mysystem2("echo '$ctrlip' > $vnoderoot/var/emulab/boot/localevserver");
	    goto bad
		if ($?);
	}
	# XXX We need this for libsetup to know it is in a XENVM.
	if (! -e "$vnoderoot/var/emulab/boot/vmname" ) {
	    mysystem2("echo '$vnode_id' > $vnoderoot/var/emulab/boot/vmname");
	    goto bad
		if (0 && $?);
	}
	# change the devices in fstab
	my $ldisk = ($xeninfo{xen_major} >= 4 ? "xvd" : "sd");

	mysystem2("sed -i -e 's;^/dev/[hs]d;/dev/${ldisk};' ".
		  "  $vnoderoot/etc/fstab");
	goto bad
	    if ($?);

	# remove swap partitions from fstab
	mysystem2("sed -i -e '/swap/d' $vnoderoot/etc/fstab");

	# enable the correct device for console
	if (-f "$vnoderoot/etc/inittab") {
	    mysystem2("sed -i.bak -e 's/xvc0/console/' ".
		      "  $vnoderoot/etc/inittab");
	}
	if (-f "$vnoderoot/etc/init/ttyS0.conf") {
	    mysystem2("sed -i.bak -e 's/ttyS0/hvc0/' ".
		      "  $vnoderoot/etc/init/ttyS0.conf");
	}
	#
	# Change the password if possible. If something goes wrong,
	# it is handy to be able to get on on the console. 
	#
	if (exists($vnconfig->{'config'}->{'ROOTHASH'})) {
	    my $hash = $vnconfig->{'config'}->{'ROOTHASH'};

	    mysystem2("sed -i.bak -e 's,root:[^:]*,root:$hash,' ".
		      "  $vnoderoot/etc/shadow");
	    if (system("grep -q toor $vnoderoot/etc/shadow") == 0) {
		mysystem2("sed -i.bak -e 's,toor:[^:]*,toor:$hash,' ".
			  "  $vnoderoot/etc/shadow");
	    }
	}
	
	# Testing a theory; remove all this iscsi stuff to see if that
	# is causing problems with the control network interface going
	# offline after boot.
	mysystem2("/bin/rm -vf $vnoderoot/etc/init/*iscsi*");
	mysystem2("/bin/rm -vf $vnoderoot/etc/init.d/*iscsi*");
    }
    else {
	#
	# XXX We need this for libsetup to know it is in a XENVM.
	# Note that the FreeBSD images put /var on another partition
	# and it would be difficult to get that mounted.  So stick it
	# in /etc/emulab, and arrange for rc.local to move it into
	# place.
	#
	if (! -e "$vnoderoot/etc/emulab/vmname" ) {
	    mysystem2("echo '$vnode_id' > $vnoderoot/etc/emulab/vmname");
	    goto bad
		if ($?);
	}
	if (! -e "$vnoderoot/etc/rc.local" ) {
	    mysystem2("echo '#!/bin/sh' > $vnoderoot/etc/rc.local");
	    goto bad
		if ($?);
	}
	open(RCL, ">>$vnoderoot/etc/rc.local") 
	    or goto bad;
	print RCL "\n";
	print RCL "if [ -e \"/etc/emulab/vmname\" ]; then\n";
	print RCL "    /bin/mv -f /etc/emulab/vmname /var/emulab/boot\n";
	print RCL "fi\n\n";
	close(RCL);
	mysystem2("/bin/chmod +x $vnoderoot/etc/rc.local");
	    goto bad
		if ($?);
	
	my $ldisk = "da0s1";
	if (-e "$vnoderoot/etc/dumpdates") {
	    mysystem2("sed -i -e 's;^/dev/[ad][da][04]s1;/dev/$ldisk;' ".
		      "  $vnoderoot/etc/dumpdates");
	    goto bad
		if ($?);
	}
	mysystem2("sed -i -e 's;^/dev/[ad][da][04]s1;/dev/$ldisk;' ".
		  "  $vnoderoot/etc/fstab");
	goto bad
	    if ($?);

	#
	# In HVM the emulated RTC is UTC.
	# Make sure FreeBSD knows that.
	#
	if ($vninfo->{'ishvm'}) {
	    unlink("$vnoderoot/etc/wall_cmos_clock");
	}
    }
    #
    # We have to do what slicefix does when it localizes an image.
    #
    mysystem2("$LOCALIZEIMG $vnoderoot");
    goto bad
	if ($?);
    
    $retval = &$callback($vnoderoot);
  done:
    mysystem("umount $dev");
    return $retval;
  bad:
    mysystem("umount $dev");
    return 1;
}

#
# Configure the control network for a vnode.
#
# XXX for now, I just perform all the actions here til everything is working.
# This means they cannot easily be undone if something fails later on.
#
sub vnodePreConfigControlNetwork($$$$$$$$$$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private,
	$ip,$mask,$mac,$gw, $vname,$longdomain,$shortdomain,$bossip) = @_;
    my $vninfo = $private;

    if (!exists($vninfo->{'cffile'})) {
	die("libvnode_xen: vnodePreConfig: no state for $vnode_id!?");
    }
    my $network = inet_ntoa(inet_aton($ip) & inet_aton($mask));

    # Now allow routable control network.
    my $isroutable = isRoutable($ip);

    my $fmac = fixupMac($mac);
    my (undef,$ctrlip) = findControlNet();
    # Note physical host control net IF is really a bridge
    my ($cbridge) = ($ISREMOTENODE ? ($BRIDGENAME) : findControlNet());
    my $cscript = "$VMDIR/$vnode_id/cnet-$mac";

    # Save info for the control net interface for config file.
    $vninfo->{'cnet'} = {};
    $vninfo->{'cnet'}->{'mac'} = $fmac;
    $vninfo->{'cnet'}->{'bridge'} = $cbridge;
    $vninfo->{'cnet'}->{'script'} = $cscript;
    $vninfo->{'cnet'}->{'ip'} = $ip;

    # Create a network config script for the interface
    my $stuff = {'name' => $vnode_id,
		 'ip' => $ip,
		 'hip' => $gw,
		 'fqdn', => $longdomain,
		 'mac' => $fmac};
    createControlNetworkScript($vmid, $stuff, $cscript);

    #
    # Set up the chains. We always create them, and if there is no
    # firewall, they default to accept. This makes things easier in
    # the control network script (emulab-cnet.pl).
    #
    # Do not worry if these fail; we will catch it below when we add
    # the rules. Or I could look to see if the chains already exist,
    # but why bother.
    #
    DoIPtables("-N INCOMING_${vnode_id}");
    DoIPtables("-F INCOMING_${vnode_id}");
    DoIPtables("-N OUTGOING_${vnode_id}");
    DoIPtables("-F OUTGOING_${vnode_id}");

    # Match existing dynamic rules as early as possible.
    DoIPtables("-A INCOMING_${vnode_id} -m conntrack ".
	       "  --ctstate RELATED,ESTABLISHED -j ACCEPT");
    DoIPtables("-A OUTGOING_${vnode_id} -m conntrack ".
	       "  --ctstate RELATED,ESTABLISHED -j ACCEPT");
    
    if ($vnconfig->{'fwconfig'}->{'fwinfo'}->{'TYPE'} eq "none") {
	DoIPtables("-A INCOMING_${vnode_id} -j ACCEPT") == 0
	    or return -1;
	DoIPtables("-A OUTGOING_${vnode_id} -j ACCEPT") == 0
	    or return -1;
    }
    else {
	my @rules = ();

	if (0) {
	    push(@rules, "-A INCOMING_${vnode_id} -j LOG ".
		 "  --log-prefix 'IIN ${vnode_id}: ' --log-level 5");
	    push(@rules, "-A OUTGOING_${vnode_id} -j LOG ".
		 "  --log-prefix 'OOUT ${vnode_id}: ' --log-level 5");
	}

	#
	# These rules allows the container to talk to the TMCC proxy.
	# If you change this port, change emulab-cnet.pl too.
	#
	my $local_tmcd_port = $TMCD_PORT + $vmid;
	push(@rules,
	     "-A OUTGOING_${vnode_id} -p tcp ".
	     "-d $ctrlip --dport $local_tmcd_port ".
	     "-m conntrack --ctstate NEW -j ACCEPT");
	push(@rules,
	     "-A OUTGOING_${vnode_id} -p udp ".
	     "-d $ctrlip --dport $local_tmcd_port ".
	     "-m conntrack --ctstate NEW -j ACCEPT");

	#
	# Need to do some substitution first.
	#
	foreach my $rule (@{ $vnconfig->{'fwconfig'}->{'fwrules'} }) {
	    my $rulestr = $rule->{'RULE'};
	    $rulestr =~ s/\s+me\s+/ $ctrlip /g;
	    $rulestr =~ s/\s+INSIDE\s+/ OUTGOING_${vnode_id} /g;
	    $rulestr =~ s/\s+OUTSIDE\s+/ INCOMING_${vnode_id} /g;
	    $rulestr =~ s/^iptables //;
	    push(@rules, $rulestr);
	}

	#
	# For debugging, we want to log any packets that get to the bottom,
	# since they are going to get dropped.
	#
	if (0) {
	    push(@rules, "-A INCOMING_${vnode_id} -j LOG ".
		 "  --log-prefix 'IN ${vnode_id}: ' --log-level 5");
	    push(@rules, "-A OUTGOING_${vnode_id} -j LOG ".
	     "  --log-prefix 'OUT ${vnode_id}: ' --log-level 5");
	}
	
	DoIPtables(@rules) == 0
	    or return -1;
    }

    # Create a DHCP entry
    $vninfo->{'dhcp'} = {};
    $vninfo->{'dhcp'}->{'name'} = $vnode_id;
    $vninfo->{'dhcp'}->{'ip'} = $ip;
    $vninfo->{'dhcp'}->{'mac'} = $fmac;

    # a route to reach the vnodes. Do it for the entire network,
    # and no need to remove it.
    if (!$ISREMOTENODE && system("$NETSTAT -r | grep -q $network")) {
	mysystem2("$ROUTE add -net $network netmask $mask dev $cbridge");
	if ($?) {
	    return -1;
	}
    }
    return 0;
}

#
# This is where new interfaces get added to the experimental network.
# For each vnode we need to:
#  - possibly create (or arrange to have created) a bridge device
#  - create config file lines for each interface
#  - arrange for the correct routing
#
sub vnodePreConfigExpNetwork($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;
    my $vninfo = $private;
    my $ifconfigs  = $vnconfig->{'ifconfig'};
    my $ldconfigs  = $vnconfig->{'ldconfig'};
    my $tunconfigs = $vnconfig->{'tunconfig'};
    my $ifbs;

    # Keep track of links (and implicitly, bridges) that need to be created
    my @links = ();

    # Build up a config file line for all interfaces, starting with cnet
    my $vifstr = "vif = ['" .
	"mac=" . $vninfo->{'cnet'}->{'mac'} . ", " .
	# This tells vif-bridge to use antispoofing iptable rules.
	"ip=" . $vninfo->{'cnet'}->{'ip'} . ", " .
        "bridge=" . $vninfo->{'cnet'}->{'bridge'} . ", " .
	# For vif-route.
        "gatewaydev=" . $vninfo->{'cnet'}->{'bridge'} . ", " .
        "script=" . $vninfo->{'cnet'}->{'script'} . "'";

    #
    # Grab all of the IFBs we need. 
    #
    if (@$ldconfigs) {
	$ifbs = AllocateIFBs($vmid, $ldconfigs, $private);
	if (! defined($ifbs)) {
	    return -1;
	}
    }

    foreach my $interface (@$ifconfigs){
        print "interface " . Dumper($interface) . "\n"
	    if ($debug > 1);
        my $mac = "";
        my $physical_mac = "";
	my $physical_dev;
        my $tag = 0;
	my $ifname = "veth.${vmid}." . $interface->{'ID'};
	
	#
	# In the era of shared nodes, we cannot name the bridges
	# using experiment local names (e.g., the link name).
	# Bridges are now named after either the physical interface
	# they are associated with or the "tag" if there is no physical
	# interface.
	#
        my $brname;

	if ($interface->{'ITYPE'} eq "loop") {
	    #
	    # No physical device. Its a loopback (trivial) link/lan
	    # All we need is a common bridge to put the veth ifaces into.
	    #
	    $brname = "br" . $interface->{'VTAG'};
            $mac = $interface->{'MAC'};
	}
	elsif ($interface->{'ITYPE'} eq "veth"){
	    #
	    # We will never see a veth on a shared node, thus they
	    # have already been created during the physnode config.
	    #
            $mac = $interface->{'MAC'};
            if ($interface->{'PMAC'} ne "none"){
                $physical_mac = $interface->{'PMAC'};
		$brname = "br" . findIface($interface->{'PMAC'});
            }
	    else {
		$brname = "br" . $interface->{'VTAG'};
	    }
        }
	elsif ($interface->{'ITYPE'} eq "vlan"){
	    my $iface = $interface->{'IFACE'};
	    my $vtag  = $interface->{'VTAG'};
	    #
	    # On a shared node, these interfaces might not exist. This will
	    # happen when the bridges are created, for lack of a better
	    # place. 
	    #
            $mac = $interface->{'MAC'};
            $tag = $interface->{'VTAG'};
            $physical_mac = $interface->{'PMAC'};
	    $physical_dev = "${iface}.${vtag}";
	    $brname = "br" . $physical_dev;
	}
	else {
            $mac = $interface->{'MAC'};
	    $brname = "pbr" . findIface($interface->{'MAC'});
        }

	#
	# If there is shaping info associated with the interface
	# then we need a custom script. We also need an IFB for
	# ingress shaping.
	#
	my $script = "";
	foreach my $ldinfo (@$ldconfigs) {
	    if ($ldinfo->{'IFACE'} eq $mac) {
		$script = "$VMDIR/$vnode_id/enet-$mac";
		my $sh  = "${script}.sh";
		my $log = "${script}.log";
		my $tag = "$vnode_id:" . $ldinfo->{'LINKNAME'};
		my $ifb = pop(@$ifbs);

		createExpNetworkScript($vmid, $interface, $brname,
				       $ldinfo, "ifb$ifb", $script, $sh, $log);
	    }
	}

	# add interface to config file line
	$vifstr .= ", 'vifname=$ifname, mac=" .
	    fixupMac($mac) . ", bridge=$brname";
	if ($script ne "") {
	    $vifstr .= ", script=$script";
	}
	$vifstr .= "'";

	# Push vif info
        my $link = {'mac' => fixupMac($mac),
		    'ifname' => $ifname,
                    'brname' => $brname,
		    'script' => $script,
                    'physical_mac' => $physical_mac,
                    'physical_dev' => $physical_dev,
                    'tag' => $tag,
		    'itype' => $interface->{'ITYPE'},
                    };

	# Prototyping hack for Nick.
	my $envvar = $interface->{"LAN"} . "_nomac_learning";
	if (exists($vnconfig->{'environment'}->{$envvar}) &&
	    $vnconfig->{'environment'}->{$envvar}) {
	    $link->{'nomac_learning'} = 1;
	}
        push @links, $link;
    }

    #
    # Tunnels
    #
    if (values(%{ $tunconfigs })) {
	#
	# gres and route tables are a global resource.
	#
	if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 900) != TBSCRIPTLOCK_OKAY()) {
	    print STDERR "Could not get the global lock after a long time!\n";
	    return -1;
	}
	my %key2gre = ();
	my $maxgre  = 0;
	
	foreach my $tunnel (values(%{ $tunconfigs })) {
	    my $style = $tunnel->{"tunnel_style"};

	    next
		if (! ($style eq "egre"));

	    my $name     = $tunnel->{"tunnel_lan"};
	    my $srchost  = $tunnel->{"tunnel_srcip"};
	    my $dsthost  = $tunnel->{"tunnel_dstip"};
	    my $inetip   = $tunnel->{"tunnel_ip"};
	    my $peerip   = $tunnel->{"tunnel_peerip"};
	    my $mask     = $tunnel->{"tunnel_ipmask"};
	    my $unit     = $tunnel->{"tunnel_unit"};
	    my $grekey   = $tunnel->{"tunnel_tag"};
	    my $mac      = undef;

	    if (exists($tunnel->{"tunnel_mac"})) {
		$mac = $tunnel->{"tunnel_mac"};
	    }
	    else {
		$mac = GenFakeMac();
	    }

	    #
	    # Need to create an openvswitch bridge and gre tunnel inside.
	    # We can then put the veth device into the bridge. 
	    #
	    # These are the devices outside the container. 
	    my $veth = "greth.${vmid}.${unit}";
	    my $gre  = "gre$vmid.$unit";
	    my $br   = "br$vmid.$unit";
	    if (! -e "/sys/class/net/$br/flags") {
		mysystem2("$OVSCTL add-br $br");
		if ($?) {
		    TBScriptUnlock();
		    return -1;
		}
		# Record tunnel bridge created. 
		$private->{'tunnelbridges'}->{$br} = $br;

		#
		# Watch for a tunnel to a container on this same node,
		# and create a patch port instead, since gre will fail.
		#
		if ($srchost eq $dsthost) {
		    #
		    # We need to form a pair of patch port names that
		    # both sides can agree on and be unique. Both sides
		    # know the tag (gre key) and both sides know both IPs.
		    # So use the tag, and concat the last octet of the IPs.
		    #
		    my ($myoctet)  = ($inetip =~ /\d+\.\d+\.\d+\.(\d+)/);
		    my ($hisoctet) = ($peerip =~ /\d+\.\d+\.\d+\.(\d+)/);

		    my $myport   = "g" . $grekey . "." . $myoctet;
		    my $hisport  = "g" . $grekey . "." . $hisoctet;
		    
		    mysystem2("$OVSCTL add-port $br $myport -- ".
			      " set interface $myport type=patch ".
			      "                       options:peer=$hisport");
		}
		else {
		    mysystem2("$OVSCTL add-port $br $gre -- ".
			      "  set interface $gre ".
			      "  type=gre options:remote_ip=$dsthost " .
			      "           options:local_ip=$srchost " .
			      (1 ? "      options:key=$grekey" : ""));
		}
		if ($?) {
		    TBScriptUnlock();
		    return -1;
		}
	    }

	    #
	    # Create a wrapper script. All work handled in emulab-tun.pl
	    #
	    my ($imac,$omac) = build_fake_macs($mac);
	    my $script = "$VMDIR/$vnode_id/tun-$name";
	    $imac = fixupMac($imac);
	    $omac = fixupMac($omac);

	    if (createTunnelScript($vmid, $script, $omac, $br, $veth)) {
		print STDERR "Could not create tunnel script for $name\n";
		TBScriptUnlock();
		return -1;
	    }

	    # add interface to config file line
	    $vifstr .= ", 'vifname=$veth, mac=$imac, script=$script'";
	}
	TBScriptUnlock();
    }

    # push out config file line for all interfaces
    # XXX note that we overwrite since a modify might add/sub IFs
    $vifstr .= "]";
    addConfig($vninfo, $vifstr, 1);

    $vninfo->{'links'} = \@links;
    return 0;
}

sub vnodeConfigResources($$$$){
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;
    my $attributes = $vnconfig->{'attributes'};
    my $memory;

    #
    # Give the vnode some memory. The server usually tells us how much. 
    #
    if (exists($attributes->{'VM_MEMSIZE'})) {
	# Better be MB.
	$memory = $attributes->{'VM_MEMSIZE'};
    }
    else  {
	$memory = 128;
    }
    addConfig($private, "memory = $memory", 1);
    return 0;
}

sub vnodeConfigDevices($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;
    my $vninfo = $private;

    # DHCP entry...
    if (exists($vninfo->{'dhcp'})) {
	my $name = $vninfo->{'dhcp'}->{'name'};
	my $ip = $vninfo->{'dhcp'}->{'ip'};
	my $mac = $vninfo->{'dhcp'}->{'mac'};
	addDHCP($name, $ip, $mac, 1) == 0
	    or die("libvnode_xen: vnodeBoot $vnode_id: dhcp setup error!");
    }

    # physical bridge devices...
    if (createExpBridges($vmid, $vninfo->{'links'}, $private)) {
	die("libvnode_xen: vnodeBoot $vnode_id: could not create bridges");
    }
    return 0;
}

sub vnodeState($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;

    my $err = 0;
    my $out = VNODE_STATUS_UNKNOWN();

    # right now, if it shows up in the list, consider it running
    if (domainExists($vnode_id)) {
	$out = VNODE_STATUS_RUNNING();
    }
    # otherwise, if the logical (root) disk exists, consider it stopped
    elsif (exists($private->{'disks'}->{$vnode_id})) {
	my $lvname;
	if (ref($private->{'disks'}->{$vnode_id})) {
	    ($lvname) = @{ $private->{'disks'}->{$vnode_id} };
	}
	else {
	    $lvname = $private->{'disks'}->{$vnode_id};
	}
	if (findLVMLogicalVolume($lvname)) {
	    $out = VNODE_STATUS_STOPPED();
	}
    }
    return ($err, $out);
}

sub vnodeBoot($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;
    my $vninfo = $private;
    my $ip = $vninfo->{'dhcp'}->{'ip'};

    if (!exists($vninfo->{'cffile'})) {
	print STDERR "vnodeBoot $vnode_id: no essential state!\n";
	return -1;
    }

    #
    # We made it here without error, so create persistent state.
    # Xen config file...
    #
    my $config = configFile($vnode_id);
    if ($vninfo->{'cfchanged'}) {
	if (createXenConfig($config, $vninfo->{'cffile'})) {
	    print STDERR "vnodeBoot $vnode_id: could not create $config\n";
	    return -1;
	}
    } elsif (! -e $config) {
	print STDERR "vnodeBoot $vnode_id: $config file does not exist!\n";
	return -1;
    }

    # notify stated that we are about to boot
    libutil::setState("BOOTING");

    #
    # We are going to watch for a busted control network interface, which
    # happens a lot. There is a problem with the control vif not working,
    # no idea why, some kind of XEN bug. But the symptom is easy enough
    # to catch (no reply to pings), and retry. 
    #
    for (my $i = 0; $i < 3; $i++) {
	my $status = RunWithLock("xmtool", "nice $XM create $config");
	if ($status) {
	    print STDERR "$XM create failed: $status\n";
	    return -1;
	}
	my $countdown = 10;
	while ($countdown >= 0) {
	    print "Pinging $ip. Five pings only please ...\n";
	    system("ping -q -c 5 -t 5 $ip > /dev/null 2>&1");
	    # Ping returns zero if any packets received.
	    if (! $?) {
		print "Created virtual machine $vnode_id\n";
		return 0;
	    }
	    $countdown--;
	}
	#
	# Tear it down and try again. Use vnodeHalt cause it protects
	# itself with an alarm.
	#
	print "Container did not start, halting for retry ...\n";
	vnodeHalt($vnode_id, $vmid, $vnconfig, $private);
	print "Container halted, waiting for it to disappear ...\n";
	$countdown = 10;
	while ($countdown >= 0) {
	    sleep(5);
	    last
		if (! domainExists($vnode_id));
	    $countdown--;
	    print "Container not gone yet\n";
	}
	print "Container is gone ($i)!\n";
    }
    return -1;
}

sub vnodePostConfig($)
{
    return 0;
}

sub vnodeReboot($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;

    if ($vmid =~ m/(.*)/){
        $vmid = $1;
    }
    my $status = RunWithLock("xmtool", "$XM reboot $vmid");
    return $status >> 8;
}

sub vnodeTearDown($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;

    # Lots of shared resources 
    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 900) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global vz lock after a long time!\n";
	return -1;
    }

    #
    # Unwind anything we did.
    #

    # Delete the tunnel devices.
    if (exists($private->{'tunnels'})) {
	foreach my $iface (keys(%{ $private->{'tunnels'} })) {
	    mysystem2("/sbin/ip tunnel del $iface");
	    goto badbad
		if ($?);
	    delete($private->{'tunnels'}->{$iface});
	}
    }
    # Delete the ip rules.
    if (exists($private->{'iprules'})) {
	foreach my $iface (keys(%{ $private->{'iprules'} })) {
	    mysystem2("$IPBIN rule del iif $iface");
	    goto badbad
		if ($?);
	    delete($private->{'iprules'}->{$iface});
	}
    }
    #
    # Release the route tables.
    #
    ReleaseRouteTables($vmid, $private)
	if (exists($private->{'routetables'}));

  badbad:
    TBScriptUnlock();
    return 0;
}

sub vnodeDestroy($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;
    my $vninfo = $private;

    #
    # vmid might not be set if vnodeCreate did not succeed. But
    # we still come through here to clean things up.
    #
    if ($vnode_id =~ m/(.*)/){
        $vnode_id = $1;
    }
    if (domainExists($vnode_id)) {
	RunWithLock("xmtool", "$XM destroy $vnode_id");
	# XXX hang out awhile waiting for domain to disappear
	domainGone($vnode_id, 15);
    }

    # Always do this.
    return -1
	if (vnodeTearDown($vnode_id, $vmid, $vnconfig, $private));

    # Kill the chains.
    DoIPtables("-F INCOMING_${vnode_id}");
    DoIPtables("-X INCOMING_${vnode_id}");
    DoIPtables("-F OUTGOING_${vnode_id}");
    DoIPtables("-X OUTGOING_${vnode_id}");

    # DHCP entry...
    if (exists($vninfo->{'dhcp'})) {
	my $mac = $vninfo->{'dhcp'}->{'mac'};
	subDHCP($mac, 1);
    }

    #
    # We do these whether or not the domain existed
    #
    # Note to Mike from Leigh; this should maybe move to TearDown above?
    #
    destroyExpBridges($vmid, $private) == 0
	or return -1;

    #
    # We keep the IMQs until complete destruction. We do this cause we do
    # want to get into a situation where we stopped a container to do
    # something like take a disk snapshot, and then not be able to
    # restart it cause there are no more resources available (as might
    # happen on a shared node).
    #
    ReleaseIFBs($vmid, $private)
	if (exists($private->{'ifbs'}));

    # Destroy the all the disks.
    foreach my $key (keys(%{ $private->{'disks'} })) {
	my $lvname;
	if (ref($private->{'disks'}->{$key})) {
	    ($lvname) = @{ $private->{'disks'}->{$key} };
	}
	else {
	    $lvname = $private->{'disks'}->{$key};
	}
	if (findLVMLogicalVolume($lvname)) {
	    if ($lvname eq $vnode_id) {
		my $rootvndisk = lvmVolumePath($lvname);
		RunWithLock("kpartx", "kpartx -dv $rootvndisk");
	    }
	    if (mysystem2("lvremove -f $VGNAME/$lvname")) {
		print STDERR "libvnode_xen: could not destroy disk $lvname!\n";
	    }
	    else {
		delete($private->{'disks'}->{$key});
	    }
	}
    }
    return 0;
}

sub vnodeHalt($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;

    if ($vnode_id =~ m/(.*)/) {
        $vnode_id = $1;
    }
    #
    # This runs async so use -w to wait until actually destroyed!
    # The problem is that sometimes the container will not die
    # and we just sit here waiting forever. So lets set up an alarm
    # so that we give up after a while and just destroy it. This
    # is okay since we are not doing migration, and all other state
    # is retained.
    #
    my $childpid = fork();
    if ($childpid) {
	local $SIG{ALRM} = sub { kill("TERM", $childpid); };
	alarm 90;
	waitpid($childpid, 0);
	my $stat = $?;
	alarm 0;

	#
	# Any failure, do a destroy.
	#
	if ($stat) {
	    print STDERR "$XM shutdown returned $stat. Doing a destroy!\n";
	    my $status = RunWithLock("xmtool", "$XM destroy $vnode_id");
	    fatal("Could not destroy $vnode_id")
		if ($status);
	}
    }
    else {
	#
	# We have blocked most signals in mkvnode, including TERM.
	# Temporarily unblock and set to default so we die. 
	#
	local $SIG{TERM} = 'DEFAULT';
	my $status = RunWithLock("xmtool", "$XM shutdown -w $vnode_id");
	exit($status >> 8);
    }
    return 0;
}

# XXX implement these!
sub vnodeExec($$$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private, $command) = @_;

    if ($command eq "sleep 100000000") {
	while (1) {
	    my $stat = domainStatus($vnode_id);
	    # shutdown/destroyed
	    if (!$stat) {
		return 0;
	    }
	    # crashed
	    if ($stat =~ /c/) {
		return -1;
	    }
	    sleep(5);
	}
    }
    return -1;
}

sub vnodeUnmount($$$$)
{
    my ($vnode_id, $vmid, $vnconfig, $private) = @_;

    return 0;
}

#
# Local functions
#

sub findRoot()
{
    my $rootfs = `df / | grep /dev/`;
    if ($rootfs =~ /^(\/dev\/\S+)/) {
	my $dev = $1;
	return $dev;
    }
    die "libvnode_xen: cannot determine root filesystem";
}

sub copyRoot($$)
{
    my ($from, $to) = @_;
    my $disk_path = "/mnt/xen/disk";
    my $root_path = "/mnt/xen/root";
    print "Mount root\n";
    mkpath(['/mnt/xen/root']);
    mkpath(['/mnt/xen/disk']);
    # This is a nice way to avoid traversing NFS filesystems. 
    mysystem("mount $from $root_path");
    mysystem("mount -o async $to $disk_path");
    mkpath([map{"$disk_path/$_"} qw(proc sys home tmp)]);
    print "Copying files\n";
    system("nice cp -a $root_path/* $disk_path");

    # hacks to make things work!
    disk_hacks($disk_path);

    mysystem("umount $root_path");
    mysystem("umount $disk_path");
}

#
# Create the root "disk" (logical volume)
# XXX this is a temp hack til all vnode creations have an explicit image.
#
sub createRootDisk($)
{
    my ($lv) = @_;
    my $lvname = "image+" . $lv;
    my $full_path = lvmVolumePath($lvname);
    my $mountpoint= "/mnt/$lv";

    #
    # We only want to do this once. Lets wrap in an eval since
    # there are so many ways this will die.
    #
    eval {
	mysystem("lvcreate -n rootdisk -L ${XEN_LDSIZE}k $VGNAME");
	my $vndisk = lvmVolumePath("rootdisk");
	
	#
	# Put an MBR in so that it is exactly the correct size.
	#
	my $sectors = $XEN_LDSIZE * 2;
	mysystem("echo '0,$sectors,L' | sfdisk --force -u S $vndisk -N0");

	# Need the device special file.
	RunWithLock("kpartx", "kpartx -av $vndisk");

	my $dev = "$VGNAME/rootdisk1";
	$dev =~ s/\-/\-\-/g;
	$dev =~ s/\//\-/g;
	$dev = "/dev/mapper/$dev";

	mysystem("mke2fs -j -q $dev");
	
	copyRoot(findRoot(), $dev);

	#
	# Now imagezip it for space/time efficiency later.
	#
	mysystem("nice $IMAGEZIP -o -l -s 1 $dev $EXTRAFS/rootdisk.ndz");

	#
	# Now kill off the lvm and create one for the compressed version.
	# Need to know the number of CHUNKS for later.
	#
	RunWithLock("kpartx", "kpartx -dv $vndisk");
	mysystem("lvremove -f $VGNAME/rootdisk");

	my (undef,undef,undef,undef,undef,undef,undef,$lvsize) =
	    stat("$EXTRAFS/rootdisk.ndz");

	my $chunks = $lvsize / (1024 * 1024);
	$defaultImage{'IMAGECHUNKS'} = $chunks;
	$defaultImage{'LVSIZE'}      = $XEN_LDSIZE;

	# Mark as being inside an FS.
	$defaultImage{'FROMFILE'} = "$EXTRAFS/rootdisk.ndz";

	# This was modified, so save out for next time. 
	StoreImageMetadata($lv, \%defaultImage)
    };
    if ($@) {
	fatal("$@");
    }
    return 0;
}

#
# Create primary disk.
#
sub CreatePrimaryDisk($$$$)
{
    my ($lvname, $imagemetadata, $target, $extrafs) = @_;

    #
    # If this image is a delta, we have to go back to the base and start
    # with it. Then lay down each delta on top if it. 
    #
    my @deltas = ();
    if (exists($imagemetadata->{'PARENTIMAGE'})) {
	while (exists($imagemetadata->{'PARENTIMAGE'})) {
	    my $parent = $imagemetadata->{'PARENTIMAGE'};
	    my $parent_metadata;
	    LoadImageMetadata($parent, \$parent_metadata);

	    push(@deltas, $imagemetadata);
	    $imagemetadata = $parent_metadata;
	}
	$lvname = "image+" . $imagemetadata->{'IMAGENAME'};
    }
    my $basedisk   = lvmVolumePath($lvname);
    my $rootvndisk = lvmVolumePath($target);
    my $loadslice  = $imagemetadata->{'PART'};
    my $chunks     = $imagemetadata->{'IMAGECHUNKS'};
    my $lv_size;
    
    if (exists($imagemetadata->{'LVSIZE'})) {
	$lv_size = $imagemetadata->{'LVSIZE'};
    }
    else {
	#
	# The basedisk now contains the ndz data, so we need to
	# run imagedump on it to find out how big it will be when
	# uncompressed.
	#
	foreach my $line
	    (`dd if=$basedisk bs=1M count=$chunks | $IMAGEDUMP - 2>&1`){
		# N.B.: lastsect+1 == # sectors, +1 again to round up
		if ($line =~ /covered sector range: \[(\d+)-(\d+)\]/) {
		    $lv_size = ($2 + 1 + 1) / 2;
		    last;
		}
	}
	if (!defined($lv_size)) {
	    print STDERR "libvnode_xen: could not get size of $basedisk\n";
	    return -1;
	}
	$imagemetadata->{'LVSIZE'} = $lv_size;
	StoreImageMetadata($imagemetadata->{'IMAGENAME'}, $imagemetadata);
    }
    
    #
    # Add room for "empty" slice, swap partition and for extra disk.
    #
    if ($loadslice != 0) {
	$lv_size += $XEN_EMPTYSIZE;
	$lv_size += $XEN_SWAPSIZE;
	if (defined($extrafs)) {
	    # In GB, so convert to K
	    $lv_size += $extrafs * (1024 * 1024);
	}
    }
    if (mysystem2("lvcreate -L ${lv_size}k -n $target $VGNAME")) {
	print STDERR "libvnode_xen: could not create disk for $target\n";
	return -1;
    }

    #
    # If not a whole disk image, need to construct an MBR.
    #
    if ($loadslice != 0) {
	#
	# HVM FreeBSD needs real MBR boot code.
	#
	# XXX chicken-and-egg problem here: we cannot extract the boot
	# code until we have layed down the initial virtual disk (which
	# we are doing now...) but we have to put down the boot code
	# before we run sfdisk to fill in the partition table. So we
	# fall back on a hardwired copy of the bootcode. This could all
	# go away if we didn't boot via the MBR...
	#
	if ($imagemetadata->{'PARTOS'} =~ /freebsd/i &&
	    $imagemetadata->{'OSVERSION'} >= 10) {
	    my $boot = "$VMDIR/$target/boot0";
	    if (! -e "$boot") {
		$boot = "/boot/freebsd10/boot0";
		if (! -e "$boot") {
		    print STDERR
			"libvnode_xen: no boot0 code for FreeBSD HVM boot\n";
		    return -1;
		}
	    }
	    if (mysystem2("dd if=$boot of=$rootvndisk bs=512 count=1")) {
		print STDERR "libvnode_xen: could not install FreeBSD boot0\n";
		return -1;
	    }
	}

	#
	# We put the image into the same slice that tmcd
	# tells us it should be in, but we leave the other slice
	# smallest possible since there is no reason to waste the
	# space. A snapshot of this "disk" should run on a physical
	# node if desired.
	#
	my $partfile = tmpnam();
	if (!open(FILE, ">$partfile")) {
	    print STDERR "libvnode_xen: could not create $partfile\n";
	    return -1;
	}
	my $mbrvers = 2;
	if (exists($imagemetadata->{'MBRVERS'})) {
	    $mbrvers = $imagemetadata->{'MBRVERS'};
	}

	#
	# sfdisk is very tempermental about its inputs. Using
	# sector sizes seems to be the best way to avoid complaints.
	#
	my ($slice1_size,$slice2_size);
	my ($slice1_type,$slice2_type);
	# pygrub really likes there to be an active partition.
	my ($slice1_active,$slice2_active);
	my $slice1_start = 63; 

	if ($mbrvers == 3) {
	    $slice1_start = 2048;
	    $slice1_size  = $XEN_LDSIZE_3 * 2;
	    $slice2_size  = $XEN_EMPTYSIZE * 2;
	    if ($imagemetadata->{'PARTOS'} =~ /freebsd/i) {
		$slice1_type  = "0xA5";
	    } else {
		$slice1_type  = "L";
	    }
	    $slice2_type  = 0;
	    $slice1_active= ",*";
	    $slice2_active= "";
	}
	elsif ($loadslice == 1) {
	    $slice1_size  = $XEN_LDSIZE * 2;
	    $slice2_size  = ($XEN_EMPTYSIZE * 2) - 63;
	    $slice1_type  = "0xA5";
	    $slice2_type  = 0;
	    $slice1_active= ",*";
	    $slice2_active= "";
	}
	else {
	    $slice1_size = ($XEN_EMPTYSIZE * 2) - 63;
	    $slice2_size = $XEN_LDSIZE * 2;
	    $slice1_type  = 0;
	    $slice2_type  = "L";
	    $slice1_active= "";
	    $slice2_active= ",*";
	}
	my $slice2_start = $slice1_start + $slice1_size;
	my $slice3_size  = $XEN_SWAPSIZE * 2;
	my $slice3_start = $slice2_start + $slice2_size;
	
	print FILE "$slice1_start,$slice1_size,$slice1_type${slice1_active}\n";
	print FILE "$slice2_start,$slice2_size,$slice2_type${slice2_active}\n";
	print FILE "$slice3_start,$slice3_size,S\n";

	if (defined($extrafs)) {
	    my $slice4_size  = $extrafs;
	    # In GB, so convert to sectors
	    $slice4_size = $slice4_size * (1024 * 1024) * 2;
	    my $slice4_start = $slice3_start + $slice3_size;

	    print FILE "$slice4_start,$slice4_size,0\n";
	}
	close(FILE);
		    
	if (mysystem2("cat $partfile | ".
		      "    sfdisk --force -x -D -u S $rootvndisk")) {
	    print STDERR "libvnode_xen: could not partition root disk\n";
	    return -1;
	}
	unlink($partfile);
	if (exists($imagemetadata->{'FROMFILE'})) {
	    my $ndzfile = $imagemetadata->{'FROMFILE'};
	    
	    mysystem2("time $IMAGEUNZIP -s $loadslice -f -o ".
		      "                 -W 164 $ndzfile $rootvndisk");
	}
	else {
	    mysystem2("nice dd if=$basedisk bs=1M count=$chunks | ".
		      "nice $IMAGEUNZIP -s $loadslice -f -o ".
		      "                 -W 164 - $rootvndisk");
	    return -1
		if ($?);

	    #
	    # Lay down the deltas.
	    #
	    while (@deltas) {
		my $delta_metadata = pop(@deltas);
		$lvname   = "image+" . $delta_metadata->{'IMAGENAME'};
		$basedisk = lvmVolumePath($lvname);
		$chunks   = $delta_metadata->{'IMAGECHUNKS'};
	    
		mysystem2("nice dd if=$basedisk bs=1M count=$chunks | ".
			  "nice $IMAGEUNZIP -s $loadslice -f -o ".
			  "                 -W 164 - $rootvndisk");

		return -1
		    if ($?);
	    }
	}
    }
    else {
	mysystem2("nice dd if=$basedisk bs=1M count=$chunks | ".
		  "nice $IMAGEUNZIP -f -o -W 164 - $rootvndisk");
    }
    if ($?) {
	return -1;
    }
    return 0;
}

#
# Create an extra, empty disk volume. 
#
sub createAuxDisk($$)
{
    my ($lv,$size) = @_;
    my $full_path = lvmVolumePath($lv);

    mysystem2("lvcreate -n $lv -L ${size} $VGNAME");
    if ($?) {
	return -1;
    }
    return 0;
}

#
# Create a logical volume for the image if it doesn't already exist.
#
# The reload info is now a list, so as to support deltas. The first
# image is the base, provides the full chunksize of the image; the
# chunksize of the deltas is really small. The last image is what is
# the boot image, and its timestamp is the one we care about. Note
# that we never do deltas for "packaged" images.
#
sub createImageDisk($$$)
{
    my ($image,$vnode_id,$raref) = @_;
    my $imagelockname = ImageLockName($image);

    #
    # Drop the shared lock the caller has. We are going to take an exclusive
    # lock in the function below. We will take the shared lock again
    # before returning.
    #
    TBScriptUnlock();

    #
    # Process each image in the list.
    #
    foreach my $ref (@{$raref}) {
	goto bad
	    if (downloadOneImage($vnode_id, $ref));
    }

    #
    # To recreate the image later, we have to add parent pointers
    # to the metadata so we can load each delta on top of the base.
    #
    my @images = @{$raref};
    my $child  = pop(@images);
    my $child_metadata;
    LoadImageMetadata($child->{'IMAGENAME'}, \$child_metadata);
    while (@images) {
	my $parent = pop(@images);
	my $parent_metadata;
	LoadImageMetadata($parent->{'IMAGENAME'}, \$parent_metadata);

	$child_metadata->{'PARENTIMAGE'} = $parent->{'IMAGENAME'};
	StoreImageMetadata($child->{'IMAGENAME'}, $child_metadata);

	$child = $parent;
	$child_metadata = $parent_metadata;
    }
    
    # And back to a shared lock.
    if (TBScriptLock($imagelockname, TBSCRIPTLOCK_SHAREDLOCK(), 1800)
	!= TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get $imagelockname lock back ".
	    "after a long time!\n";
	return -1;
    }
    #
    # XXX note that we don ot declare RELOADDONE here since we have not
    # actually created the vnode disk yet. That is the caller's
    # responsibility.
    #    
    return 0;
  bad:
    return -1;
}

#
# Download and create an LVM for a single compressed image.
#
sub downloadOneImage($$)
{
    my ($vnode_id, $raref) = @_;
    my $image = $raref->{'IMAGENAME'};
    my $imagelockname = ImageLockName($image);
    my $tstamp = $raref->{'IMAGEMTIME'};
    my $lvname = "image+" . $image;
    my $lvmpath = lvmVolumePath($lvname);
    my $imagedatepath = "$METAFS/${image}.date";
    my $imagemetapath = "$METAFS/${image}.metadata";
    my $imagepath = $lvmpath;
    my $unpack = 0;
    my $nochunks = 0;
    my $lv_size;

    if (TBScriptLock($imagelockname, undef, 1800) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get $imagelockname write lock".
	    "after a long time!\n";
	return -1;
    }
    
    # Ick.
    if (exists($raref->{'MBRVERS'}) && $raref->{'MBRVERS'} == 99) {
	$unpack = 1;
    }
    
    #
    # Do we have the right image file already? No need to download it
    # again if the timestamp matches. 
    #
    if (findLVMLogicalVolume($lvname)) {
	if (-e $imagedatepath) {
	    my (undef,undef,undef,undef,undef,undef,undef,undef,undef,
		$mtime,undef,undef,undef) = stat($imagedatepath);
	    if ("$mtime" eq "$tstamp") {
		#
		# We want to update the access time to indicate a new
		# use of this image, for pruning unused images later.
		#
		utime(time(), $mtime, $imagedatepath);
		print "Found existing disk: $lvmpath.\n";
		goto bad
		    if ($unpack && ! -e "/mnt/$image" &&
			mysystem2("mkdir -p /mnt/$image"));
		goto bad
		    if ($unpack && ! -e "/mnt/$image/.mounted" &&
			mysystem2("mount $imagepath /mnt/$image"));

		goto okay;
	    }
	    print "mtime for $lvmpath differ: local $mtime, server $tstamp\n";
	}
    }

    if (findLVMLogicalVolume($lvname)) {
	# For the package case.
	if (-e "/mnt/$image/.mounted" && mysystem2("umount /mnt/$image")) {
	    print STDERR "Could not umount /mnt/$image\n";
	    goto bad;
	}
	if (GClvm($lvname)) {
	    print STDERR "Could not GC or rename $lvname\n";
	    goto bad;
	}
	unlink($imagedatepath)
	    if (-e $imagedatepath);
	unlink($imagemetapath)
	    if (-e $imagemetapath);
    }

    #
    # If the version info indicates a packaged container, then we
    # create a filesystem inside the lvm and download the package to
    # it. We tell the download function to untar it, since otherwise
    # we have to make a copy.
    #
    # XXX Using MBRVERS for now, need something else.
    #
    if ($unpack) {
	$lv_size = 6 * 1024;
    }
    elsif (!exists($raref->{'IMAGECHUNKS'})) {
	print STDERR "Did not get chunksize in loadinfo. Using 6GB ...\n";
	$nochunks = 1;
	$lv_size  = 6 * 1024;
    }
    else {
	#
	# tmcd tells us number of chunks (size of image file). Create properly
	# sized LVM. 
	#
	$lv_size = $raref->{'IMAGECHUNKS'};

	#
	# tmcd may also tell us the sector range of the uncompressed data.
	# Extract useful tidbits from that.
	#
	if (exists($raref->{'IMAGELOW'}) &&
	    exists($raref->{'IMAGEHIGH'})) {
	    $raref->{'LVSIZE'} =
		(($raref->{'IMAGEHIGH'} - $raref->{'IMAGELOW'} + 1) /
		 (1024 / $raref->{'IMAGESSIZE'}));
	}
    }
    if (mysystem2("lvcreate -n $lvname -L ${lv_size}m $VGNAME")) {
	print STDERR "libvnode_xen: could not create disk for $image\n";
	goto bad;
    }
    if ($unpack) {
	goto bad
	    if (! -e "/mnt/$image" && mysystem2("mkdir -p /mnt/$image"));
	goto bad
	    if (-e "/mnt/$image/.mounted" && mysystem2("umount /mnt/$image"));
	mysystem2("mkfs -t ext3 $imagepath");
	goto bad
	    if ($?);
	mysystem2("mount $imagepath /mnt/$image");
	goto bad
	    if ($?);
	mysystem2("touch /mnt/$image/.mounted");
	goto bad
	    if ($?);
	$imagepath = "$EXTRAFS/${image}.tar.gz";
    }
    elsif ($nochunks) {
	#
	# Write to plain file so we can determine IMAGECHUNKS and reduce lvm.
	#
	$imagepath = "$EXTRAFS/${image}.ndz";
    }

    #
    # Now we just download the file, then let create do its normal thing
    #
    # Note that raref can be an array now, but downloadImage deals
    # with that. When it returns, all parts have been loaded into
    # LVM. We might improve things by putting each part into its
    # own LVM, so we have them for other images, but if the deltas are
    # small and the branching limited, it is not worth the effort.
    # Lets see how it goes ...
    #
    if (libvnode::downloadImage($imagepath, $unpack, $vnode_id, $raref)) {
	print STDERR "libvnode_xen: could not download image $image\n";
	goto bad;
    }
    if ($unpack) {
	# Now unpack the tar file, then remove it.
	mysystem2("tar zxf $imagepath -C /mnt/$image");
	goto bad
	    if ($?);
	unlink($imagepath);
	# Mark it as a package.
	$raref->{'ISPACKAGE'} = 1;
	goto bad
	    if ($?);
    }
    elsif ($nochunks) {
	my (undef,undef,undef,undef,undef,undef,undef,$fsize) =
	    stat($imagepath);

	my $chunks = $fsize / (1024 * 1024);
	$raref->{'IMAGECHUNKS'} = $chunks;
	mysystem2("lvreduce --force -L ${chunks}m $VGNAME/$lvname");
	goto bad
	    if ($?);
	mysystem2("dd if=$imagepath of=$lvmpath bs=256k");
	goto bad
	    if ($?);

	#
	# The basedisk now contains the ndz data, so we need to
	# run imagedump on it to find out how big it will be when
	# uncompressed.
	#
	my $isize;
		
	foreach my $line
	    (`dd if=$imagepath bs=1M count=$chunks | $IMAGEDUMP - 2>&1`) {
		if ($line =~ /covered sector range: \[(\d+)-(\d+)\]/) {
		    # N.B.: lastsect+1 == # sectors, +1 again to round up
		    $isize = int(($2 + 1 + 1) / 2);
		    last;
		}
	}
	if (!defined($isize)) {
	    print STDERR "libvnode_xen: could not get size of $imagepath\n";
	    goto bad;
	}
	if (exists($raref->{'LVSIZE'}) && $isize != $raref->{'LVSIZE'}) {
	    print STDERR
		"libvnode_xen: WARNING: computed LVSIZE ($isize) != ".
		"provided LVSIZE (" . $raref->{'LVSIZE'} . "); ".
		"using computed size.\n";
	}
	$raref->{'LVSIZE'} = $isize;
	unlink($imagepath);
    }
    # reload has finished, file is written... so let's set its mtime
    mysystem2("touch $imagedatepath")
	if (! -e $imagedatepath);
    utime(time(), $tstamp, $imagedatepath);

    #
    # Additional info about the image. Just store the loadinfo data.
    #
    StoreImageMetadata($image, $raref);

  okay:
    TBScriptUnlock();
    return 0;
  bad:
    TBScriptUnlock();
    return -1;
}

sub replace_hack($)
{
    my ($q) = @_;
    if ($q =~ m/(.*)/){
        return $1;
    }
    return "";
}

sub disk_hacks($)
{
    my ($path) = @_;
    # erase cache from LABEL to devices
    my @files = <$path/etc/blkid/*>;
    unlink map{&replace_hack($_)} (grep{m/(.*blkid.*)/} @files);

    rmtree(["$path/var/emulab/boot/tmcc"]);

    # Run prepare inside to clean up.
    system("/usr/sbin/chroot $path /usr/local/etc/emulab/prepare -N");

    # Fix of grub to boot non-xen env.
    system("sed -i.bak -e 's/default=.*/default=0/' $path/boot/grub/grub.cfg");

    # don't try to recursively boot vnodes!
    unlink("$path/usr/local/etc/emulab/bootvnodes");

    # don't set up the xen bridge on guests
    system("sed -i.bak -e '/xenbridge-setup/d' $path/etc/network/interfaces");

    # don't start dhcpd in the VM
    unlink("$path/etc/dhcpd.conf");
    unlink("$path/etc/dhcp/dhcpd.conf");

    # No xen daemons
    unlink("$path/etc/init.d/xend");
    unlink("$path/etc/init.d/xendomains");

    # Remove mtab just in case
    unlink("$path/etc/mtab");

    # Remove dhcp client state
    unlink("$path/var/lib/dhcp/dhclient.leases");

    # Clear out the cached control net interface name
    unlink("$path/var/run/cnet");

    # Get rid of pam nonsense.
    system("sed -i.bak -e 's/UsePAM yes/UsePAM no/'".
	   "   $path/etc/ssh/sshd_config");

    # remove swap partitions from fstab
    system("sed -i.bak -e '/swap/d' $path/etc/fstab");

    # remove scratch partitions from fstab
    system("sed -i.bak -e '/scratch/d' $path/etc/fstab");
    system("sed -i.bak -e '${EXTRAFS}/d' $path/etc/fstab");
    system("sed -i.bak -e '${METAFS}/d' $path/etc/fstab");
    system("sed -i.bak -e '${INFOFS}/d' $path/etc/fstab");

    # fixup fstab: change UUID=blah to LABEL=/
    system("sed -i.bak -e 's/UUID=[0-9a-f-]*/LABEL=\\//' $path/etc/fstab");

    # enable the correct device for console
    if (-f "$path/etc/inittab") {
	    system("sed -i.bak -e 's/xvc0/console/' $path/etc/inittab");
    }

    if (-f "$path/etc/init/ttyS0.conf") {
	    system("sed -i.bak -e 's/ttyS0/hvc0/' $path/etc/init/ttyS0.conf");
    }

    if (-e "$BINDIR/tmcc-nossl.bin") {
	system("/bin/cp -f $BINDIR/tmcc-nossl.bin $path/$BINDIR/tmcc.bin");
    }
    system("/bin/rm -rf $path/var/emulab/vms");
}

sub configFile($)
{
    my ($id) = @_;
    if ($id =~ m/(.*)/){
        return "$VMDIR/$1/xm.conf";
    }
    return "";
}

#
# Return MB of memory used by dom0
# Give it at least 256MB of memory.
#
sub domain0Memory()
{
    my $memtotal = `grep MemTotal /proc/meminfo`;
    if ($memtotal =~ /^MemTotal:\s*(\d+)\s(\w+)/) {
	my $num = $1;
	my $type = $2;
	if ($type eq "kB") {
	    $num /= 1024;
	}
	$num = int($num);
	return ($num >= $MIN_MB_DOM0MEM ? $num : $MIN_MB_DOM0MEM);
    }
    die("Could not find what the total memory for domain 0 is!");
}

#
# Return total MB of memory available to domUs
#
sub totalMemory()
{
    # returns amount in MB
    my $meminfo = `$XM info | grep total_memory`;
    if ($meminfo =~ m/\s*total_memory\s*:\s*(\d+)/){
        my $mem = int($1);
        return $mem - domain0Memory();
    }
    die("Could not find what the total physical memory on this machine is!");
}

#
# Contruct and returns the jail control net IP of the physical host.
#
sub domain0ControlNet()
{
    #
    # XXX we use a woeful hack to get the virtual control net address,
    # that is unique. I will assume that control network is never
    # bigger then /16 and so just combine the top of the jail network
    # with the lower half of the control network address.
    #
    my (undef,$vmask,$vgw) = findVirtControlNet();
    my (undef, $ctrlip, $ctrlmask) = findControlNet();
    my ($a,$b,$c,$d);

    if ($vgw =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
	$a = $1;
	$b = 31;

	my $tmp    = ~inet_aton("255.255.0.0") & inet_aton($ctrlip);
	my $ipbase = inet_ntoa($tmp);

	if ($ipbase =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
	    return ("$a.$b.$3.$4", $vmask);
	}
    }
    die("domain0ControlNet: could not create control net virtual IP");
}

#
# Emulab image compatibility: the physical host acts as DHCP server for all
# the hosted vnodes since they expect to find out there identity, and identify
# their control net, via DHCP.
#
sub createDHCP()
{
    my ($all) = @_;
    my ($vnode_net,$vnode_mask,$vnode_gw) = findVirtControlNet();
    my (undef,undef,
	$cnet_mask,undef,$cnet_net,undef,$cnet_gw) = findControlNet();

    my $vnode_dns = findDNS($vnode_gw);
    my $domain    = findDomain();
    my $file;

    if (-d "/etc/dhcp") {
	$file = $NEW_DHCPCONF_FILE;
    } else {
	$file = $DHCPCONF_FILE;
    }
    open(FILE, ">$file") or die("Cannot write $file");

    print FILE <<EOF;
#
# Do not edit!  Auto-generated by libvnode_xen.pm.
#
ddns-update-style  none;
default-lease-time 604800;
max-lease-time     704800;

shared-network xen {
subnet $vnode_net netmask $vnode_mask {
    option domain-name-servers $vnode_dns;
    option domain-name "$domain";
    option routers $vnode_gw;

    # INSERT VNODES AFTER

    # INSERT VNODES BEFORE
}

subnet $cnet_net netmask $cnet_mask {
    option domain-name-servers $vnode_dns;
    option domain-name "$domain";
    option routers $cnet_gw;

    # INSERT VNODES AFTER

    # INSERT VNODES BEFORE
}
}

EOF
    ;
    close(FILE);

    restartDHCP();
}

#
# Add or remove (host,IP,MAC) in the local dhcpd.conf
# If an entry already exists, replace it.
#
# XXX assume one line per entry
#
sub addDHCP($$$$) { return modDHCP(@_, 0); }
sub subDHCP($$) { return modDHCP("--", "--", @_, 1); }

sub modDHCP($$$$$)
{
    my ($host,$ip,$mac,$doHUP,$dorm) = @_;
    my $dhcp_config_file = $DHCPCONF_FILE;
    if (-f $NEW_DHCPCONF_FILE) {
        $dhcp_config_file = $NEW_DHCPCONF_FILE;
    }
    my $cur = "$dhcp_config_file";
    my $bak = "$dhcp_config_file.old";
    my $tmp = "$dhcp_config_file.new";

    if (TBScriptLock("dhcpd", 0, 900) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the dhcpd lock after a long time!\n";
	return -1;
    }

    if (!open(NEW, ">$tmp")) {
	print STDERR "Could not create new DHCP file, ",
		     "$host/$ip/$mac not added\n";
	TBScriptUnlock();
	return -1;
    }
    if (!open(OLD, "<$cur")) {
	print STDERR "Could not open $cur, ",
		     "$host/$ip/$mac not added\n";
	close(NEW);
	unlink($tmp);
	TBScriptUnlock();
	return -1;
    }
    my $changed = 0;
    $mac = lc($mac);
    if ($dorm) {
	while (my $line = <OLD>) {
	    if ($line =~ /ethernet ([\da-f:]+); fixed-address/i) {
		my $omac = lc($1);
		if ($mac eq $omac) {
		    # skip this entry.
		    $changed = 1;
		    next;
		}
	    }
	    print NEW $line;
	}
	goto done;
    }
    $host = lc($host);
    my $insubnet = 0;
    my $inrange = 0;
    my $found = 0;
    while (my $line = <OLD>) {
	if ($found) {
	    ;
	} elsif ($line =~ /^subnet\s*([\d\.]+)\s*netmask\s*([\d\.]+)/) {
	    my $subnet  = $1;
	    my $submask = $2;

	    #
	    # Is the IP we need to add, within this subnet?
	    #
	    $insubnet = 1
		if (inet_ntoa(inet_aton($ip) &
			      inet_aton($submask)) eq $subnet);
	} elsif ($insubnet && $line =~ /INSERT VNODES AFTER/) {
	    $inrange = 1;
	} elsif ($insubnet && $line =~ /INSERT VNODES BEFORE/) {
	    $inrange = 0;
	    $found = 1;
	    if (!$dorm) {
		print NEW formatDHCP($host, $ip, $mac), "\n";
		$changed = 1;
	    }
	} elsif ($inrange &&
		 ($line =~ /ethernet ([\da-f:]+); fixed-address ([\d\.]+); option host-name ([^;]+);/i)) {
	    my $ohost = lc($3);
	    my $oip = $2;
	    my $omac = lc($1);
	    if ($mac eq $omac) {
		if ($dorm) {
		    # skip this entry; don't mark found so we find all
		    $changed = 1;
		    next;
		}
		$found = 1;
		if ($host ne $ohost || $ip ne $oip) {
		    print NEW formatDHCP($host, $ip, $omac), "\n";
		    $changed = 1;
		    next;
		}
	    }
	}
	print NEW $line;
    }
  done:
    close(OLD);
    close(NEW);

    #
    # Nothing changed, we are done.
    #
    if (!$changed) {
	unlink($tmp);
	TBScriptUnlock();
	return 0;
    }

    #
    # Move the new file in place, and optionally restart dhcpd
    #
    if (-e $bak) {
	if (!unlink($bak)) {
	    print STDERR "Could not remove $bak, ",
			 "$host/$ip/$mac not added\n";
	    unlink($tmp);
	    TBScriptUnlock();
	    return -1;
	}
    }
    if (!rename($cur, $bak)) {
	print STDERR "Could not rename $cur -> $bak, ",
		     "$host/$ip/$mac not added\n";
	unlink($tmp);
	TBScriptUnlock();
	return -1;
    }
    if (!rename($tmp, $cur)) {
	print STDERR "Could not rename $tmp -> $cur, ",
		     "$host/$ip/$mac not added\n";
	rename($bak, $cur);
	unlink($tmp);
	TBScriptUnlock();
	return -1;
    }

    if ($doHUP) {
        restartDHCP();
    }

    TBScriptUnlock();
    return 0;
}

sub formatDHCP($$$)
{
    my ($host,$ip,$mac) = @_;
    my $xip = $ip;
    $xip =~ s/\.//g;

    return ("    host xen$xip { ".
	    "hardware ethernet $mac; ".
	    "fixed-address $ip; ".
	    "option host-name $host; }");
}

# convert 123456 into 12:34:56
sub fixupMac($)
{
    my ($x) = @_;
    $x =~ s/(\w\w)/$1:/g;
    chop($x);
    return $x;
}

#
# Write out the script that will be called when the control-net interface
# is instantiated by Xen.  This is just a stub which calls the common
# Emulab script in /etc/xen/scripts.
#
# XXX can we get rid of this stub by using environment variables?
#
sub createControlNetworkScript($$$)
{
    my ($vmid,$data,$file) = @_;
    my $host_ip = $data->{'hip'};
    my $name = $data->{'name'};
    my $ip = $data->{'ip'};
    my $mac = $data->{'mac'};

    open(FILE, ">$file") or die $!;
    print FILE "#!/bin/sh\n";
    print FILE "/bin/mv -f ${file}.debug ${file}.debug.old\n";
    print FILE "/etc/xen/scripts/emulab-cnet.pl $vmid $host_ip $name $ip $mac ".
	" \$* >${file}.debug 2>&1\n";
    print FILE "exit \$?\n";
    close(FILE);
    chmod(0555, $file);
}

#
# Write out the script that will be called when a tunnel interface
# is instantiated by Xen.  This is just a stub which calls the common
# Emulab script in /etc/xen/scripts.
#
# XXX can we get rid of this stub by using environment variables?
#
sub createTunnelScript($$$$$)
{
    my ($vmid, $file, $mac, $vbr, $veth) = @_;

    open(FILE, ">$file")
	or return -1;
    
    print FILE "#!/bin/sh\n";
    print FILE "/bin/mv -f ${file}.debug ${file}.debug.old\n";
    print FILE "/etc/xen/scripts/emulab-tun.pl ".
	"$vmid $mac $vbr $veth \$* >${file}.debug 2>&1\n";
    print FILE "exit \$?\n";
    close(FILE);
    chmod(0555, $file);
    return 0;
}

sub createExpNetworkScript($$$$$$$$)
{
    my ($vmid,$ifc,$bridge,$info,$ifb,$wrapper,$file,$lfile) = @_;
    my $TC = "/sbin/tc";

    if (! open(FILE, ">$wrapper")) {
	print STDERR "Error creating $wrapper: $!\n";
	return -1;
    }
    print FILE "#!/bin/sh\n";
    print FILE "/bin/mv -f ${lfile} ${lfile}.old\n";
    print FILE "/etc/xen/scripts/emulab-enet.pl $file \$* >${lfile} 2>&1\n";
    print FILE "exit \$?\n";
    close(FILE);
    chmod(0554, $wrapper);
    
    if (! open(FILE, ">$file")) {
	print STDERR "Error creating $file: $!\n";
	return -1;
    }
    print FILE "#!/bin/sh\n";
    print FILE "OP=\$1\n";
    print FILE "export bridge=$bridge\n";
    print FILE "/etc/xen/scripts/vif-bridge \$*\n";
    print FILE "STAT=\$?\n";
    print FILE "if [ \$STAT -ne 0 -o \"\$OP\" != \"online\" ]; then\n";
    print FILE "    exit \$STAT\n";
    print FILE "fi\n";
    print FILE "# XXX redo what vif-bridge does to get named interface\n";
    print FILE "vifname=`xenstore-read \$XENBUS_PATH/vifname`\n";
    print FILE "echo \"Configuring shaping for \$vifname (MAC ",
                     $info->{'IFACE'}, ")\"\n";

    my $iface     = $info->{'IFACE'};
    my $type      = $info->{'TYPE'};
    my $linkname  = $info->{'LINKNAME'};
    my $vnode     = $info->{'VNODE'};
    my $inet      = $info->{'INET'};
    my $mask      = $info->{'MASK'};
    my $pipeno    = $info->{'PIPE'};
    my $delay     = $info->{'DELAY'};
    my $bandw     = $info->{'BW'};
    my $plr       = $info->{'PLR'};
    my $rpipeno   = $info->{'RPIPE'};
    my $rdelay    = $info->{'RDELAY'};
    my $rbandw    = $info->{'RBW'};
    my $rplr      = $info->{'RPLR'};
    my $red       = $info->{'RED'};
    my $limit     = $info->{'LIMIT'};
    my $maxthresh = $info->{'MAXTHRESH'};
    my $minthresh = $info->{'MINTHRESH'};
    my $weight    = $info->{'WEIGHT'};
    my $linterm   = $info->{'LINTERM'};
    my $qinbytes  = $info->{'QINBYTES'};
    my $bytes     = $info->{'BYTES'};
    my $meanpsize = $info->{'MEANPSIZE'};
    my $wait      = $info->{'WAIT'};
    my $setbit    = $info->{'SETBIT'};
    my $droptail  = $info->{'DROPTAIL'};
    my $gentle    = $info->{'GENTLE'};

    $delay  = int($delay + 0.5) * 1000;
    $rdelay = int($rdelay + 0.5) * 1000;

    $bandw *= 1000;
    $rbandw *= 1000;

    my $queue = "";
    if ($qinbytes) {
	if ($limit <= 0 || $limit > (1024 * 1024)) {
	    print "Q limit $limit for pipe $pipeno is bogus, using default\n";
	}
	else {
	    $queue = int($limit/1500);
	    $queue = $queue > 0 ? $queue : 1;
	}
    }
    elsif ($limit != 0) {
	if ($limit < 0 || $limit > 100) {
	    print "Q limit $limit for pipe $pipeno is bogus, using default\n";
	}
	else {
	    $queue = $limit;
	}
    }

    my $pipe10 = $pipeno + 10;
    my $pipe20 = $pipeno + 20;
    $iface = "\$vifname";
    my $cmd;
    if ($queue ne "") {
	$cmd = "/sbin/ifconfig $iface txqueuelen $queue";
	print FILE "echo \"$cmd\"\n";
	print FILE "$cmd\n\n";
    }
    my @cmds = ();

    if ($xeninfo{xen_major} >= 4) {
	# packet loss in netem is percent
	$plr *= 100;
	$rplr *= 100;

	push(@cmds,
	     "$TC qdisc add dev $iface handle $pipe20 root htb default 1");
	if ($bandw != 0) {
	    push(@cmds,
		 "$TC class add dev $iface classid $pipe20:1 ".
		 "parent $pipe20 htb rate ${bandw} ceil ${bandw}");
	}
	push(@cmds,
	     "$TC qdisc add dev $iface handle $pipe10 parent $pipe20:1 ".
	     "netem drop $plr delay ${delay}us");

	#
	# Incoming traffic shaping.
	#
	if ($type ne "duplex") {
	    $rbandw = $bandw;
	}
 	push(@cmds, "$IFCONFIG $ifb up");
	push(@cmds, "$TC qdisc del dev $ifb root");
	push(@cmds, "$TC qdisc add dev $iface handle ffff: ingress");
	push(@cmds, "$TC filter add dev $iface parent ffff: protocol ip ".
	     "u32 match u32 0 0 action mirred egress redirect dev $ifb");
 	push(@cmds, "$TC qdisc add dev $ifb root handle 2: htb default 1");
	push(@cmds, "$TC class add dev $ifb parent 2: classid 2:1 ".
	     "htb rate ${rbandw} ceil ${rbandw}");

	if ($type eq "duplex") {
	    # Do not use a colon: in the handle. It BREAKS!
	    push(@cmds,
		 "$TC qdisc add dev $ifb handle 3 parent 2:1 ".
		 "netem drop $rplr delay ${rdelay}us");
	}
    }
    else {
	push(@cmds,
	     "$TC qdisc add dev $iface handle $pipeno root plr $plr");
	push(@cmds,
	     "$TC qdisc add dev $iface handle $pipe10 ".
	     "parent ${pipeno}:1 delay usecs $delay");
	push(@cmds,
	     "$TC qdisc add dev $iface handle $pipe20 ".
	     "parent ${pipe10}:1 htb default 1");
	if ($bandw != 0) {
	    push(@cmds,
		 "$TC class add dev $iface classid $pipe20:1 ".
		 "parent $pipe20 htb rate ${bandw} ceil ${bandw}");
	}
    }
    foreach my $cmd (@cmds) {
	print FILE "echo \"$cmd\"\n";
	print FILE "$cmd\n\n";
    }
    print FILE "exit 0\n";

    close(FILE);
    chmod(0554, $file);
    return 0;
}

sub createExpBridges($$$)
{
    my ($vmid,$linfo,$private) = @_;

    if (@$linfo == 0) {
	return 0;
    }

    #
    # Since bridges and physical interfaces can be shared between vnodes,
    # we need to serialize this.
    #
    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 1800) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global lock after a long time!\n";
	return -1;
    }

    # read the current state of affairs
    makeIfaceMaps();
    makeBridgeMaps();

    foreach my $link (@$linfo) {
	my $mac = $link->{'mac'};
	my $pmac = $link->{'physical_mac'};
	my $brname = $link->{'brname'};
	my $tag = $link->{'tag'};

	print "$vmid: looking up bridge $brname ".
	    "(mac=$mac, pmac=$pmac, tag=$tag)\n"
		if ($debug);

	#
	# Sanity checks (all fatal errors if incorrect right now):
	# Virtual interface should not exist at this point,
	# Any physical interfaces should exist,
	# If physical interface is in a bridge, it must be the right one,
	#
	my $vdev = findIface($mac);
	if ($vdev) {
	    print STDERR "createExpBridges: $vdev ($mac) should not exist!\n";
	    goto bad;
	}
	my $pdev;
	my $pbridge;
	if ($pmac ne "") {
	    #
	    # Look for vlan devices that need to be created.
	    #
	    if ($link->{'itype'} eq "vlan") {
		$pdev = $link->{'physical_dev'};
		my $iface = findIface($pmac);

		#
		# Jumbos; set MTU before we create the vlan device, which
		# will inherit that MTU. Yep, we probably do this multiple
		# times per interface, but its harmless.
		#
		mysystem2("$IFCONFIG $iface mtu 9000");
		goto bad
		    if ($?);

		if (! -d "/sys/class/net/$pdev") {
		    mysystem2("$VLANCONFIG set_name_type DEV_PLUS_VID_NO_PAD");
		    mysystem2("$VLANCONFIG add $iface $tag");
		    goto bad
			if ($?);
		    mysystem2("$VLANCONFIG set_name_type VLAN_PLUS_VID_NO_PAD");

		    #
		    # We do not want the vlan device to have the same
		    # mac as the physical device, since that will confuse
		    # findif later.
		    #
		    my $bmac = fixupMac(GenFakeMac());
		    mysystem2("$IPBIN link set $pdev address $bmac");
		    goto bad
			if ($?);
		    
		    mysystem2("$IFCONFIG $pdev up");
		    mysystem2("$ETHTOOL -K $pdev tso off gso off");
		    makeIfaceMaps();

		    # Another thing that seems to screw up, causing the ciscos
		    # to drop packets with an undersize error.
		    mysystem2("$ETHTOOL -K $iface txvlan off");
		}
	    }
	    else {
		$pdev = findIface($pmac);
	    }
	    if (!$pdev) {
		print STDERR "createExpBridges: $pdev ($pmac) should exist!\n";
		goto bad;
	    }
	    $pbridge = findBridge($pdev);
	    if ($pbridge && $pbridge ne $brname) {
		print STDERR "createExpBridges: ".
		    "$pdev ($pmac) in wrong bridge $pbridge!\n";
		goto bad;
	    }
	}

	# Create bridge if it does not exist
	if (!existsBridge($brname)) {
	    if (mysystem2("$BRCTL addbr $brname")) {
		print STDERR "createExpBridges: could not create $brname\n";
		goto bad;
	    }
	    #
	    # Bad feature of bridges; they take on the lowest numbered
	    # mac of the added interfaces (and it changes as interfaces
	    # are added and removed!). But the main point is that we end
	    # up with a bridge that has the same mac as a physical device
	    # and that screws up findIface(). But if we "assign" a mac
	    # address, it does not change and we know it will be unique.
	    #
	    my $bmac = fixupMac(GenFakeMac());
	    mysystem2("$IPBIN link set $brname address $bmac");
	    goto bad
		if ($?);
	    
	    if (mysystem2("$IFCONFIG $brname up")) {
		print STDERR "createExpBridges: could not ifconfig $brname\n";
		goto bad;
	    }
	}
	# record bridge in use.
	$private->{'physbridges'}->{$brname} = $brname;

	# Add physical device to bridge if not there already
	if ($pdev && !$pbridge) {
	    if (mysystem2("$BRCTL addif $brname $pdev")) {
		print STDERR
		    "createExpBridges: could not add $pdev to $brname\n";
		goto bad;
	    }
	}
	# Prototyping for Nick.
	if (exists($link->{'nomac_learning'})) {
	    if (mysystem2("$BRCTL setageing $brname 0")) {
		print STDERR "createExpBridges: could zero agin on $brname\n";
	    }
	}
    }
    TBScriptUnlock();
    return 0;
  bad:
    TBScriptUnlock();
    return -1;
}

sub destroyExpBridges($$)
{
    my ($vmid,$private) = @_;

    # Delete bridges we created which we know have no members.
    if (exists($private->{'tunnelbridges'})) {
	foreach my $brname (keys(%{ $private->{'tunnelbridges'} })) {
	    mysystem2("$IFCONFIG $brname down");	    
	    mysystem2("$OVSCTL del-br $brname");
	    delete($private->{'tunnelbridges'}->{$brname});
	}
    }

    #
    # In general, bridges can be shared between containers and they
    # can change while not under the lock, since vnodeboot is called
    # without the lock, and the bridges are populated by create.
    # On a non-shared node, this is not really an issue since things
    # do not change that often. On a shared node we could actually
    # get bit by this race, which is too bad, cause on a shared node
    # we could get LOTS of bridges left behind. Not sure what to
    # do about this yet, so lets not reclaim anything at the moment,
    # and I will ponder things more.
    #
    return 0
	if (1);
    
    #
    # Since bridges and physical interfaces can be shared between vnodes,
    # we need to serialize this.
    #
    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 1800) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global lock after a long time!\n";
	return -1;
    }

    if (exists($private->{'physbridges'})) {
	makeBridgeMaps();
	
	foreach my $brname (keys(%{ $private->{'physbridges'} })) {
	    my @ifaces = findBridgeIfaces($brname);
	    if (@ifaces <= 1) {
		delbr($brname);
		delete($private->{'physbridges'}->{$brname})
		    if (! $?);
	    }
	}
    }
    TBScriptUnlock();
    return 0;
}

sub domainStatus($)
{
    my ($id) = @_;

    if ($XM =~ /xl/) {
	my $status = `$XM list $id | tail -n 1 | awk '{print \$5}'`;
	if (!$? && $status =~ /([\w-]+)/) {
	    return $1;
	}
    }
    else {
	my $status = `$XM list --long $id 2>/dev/null`;
	if (!$? && $status =~ /\(state ([\w-]+)\)/) {
	    return $1;
	}
    }
    return "";
}

sub domainExists($)
{
    my ($id) = @_;    
    return (domainStatus($id) ne "");
}

sub domainGone($$)
{
    my ($id,$wait) = @_;

    while ($wait--) {
	if (!domainExists($id)) {
	    return 1;
	}
	sleep(1);
    }
    return 0;
}

#
# Add a line 'str' to the XenConfig array for vnode 'vmid'.
#
# If overwrite is set, any existing line with the same key is overwritten,
# otherwise it is ignored.  If the line doesn't exist, it is always added.
#
# XXX overwrite is a hack.  Without a full parse of the config file lines
# we cannot say that two records are "the same" in particular because some
# records contains info for multiple instances (e.g., "vif").  In those
# cases, we would need to partially overwrite lines.  But we don't,
# we just overwrite the entire line.
#
sub addConfig($$$)
{
    my ($vninfo,$str,$overwrite) = @_;
    my $vmid = $vninfo->{'vmid'};

    if (!exists($vninfo->{'cffile'})) {
	die("libvnode_xen: addConfig: no state for vnode $vmid!?");
    }
    my $aref = $vninfo->{'cffile'};

    #
    # If appending (overwrite==2) or new line is a comment, tack it on.
    #
    if ($overwrite == 2 || $str =~ /^\s*#/) {
	push(@$aref, $str);
	return;
    }

    #
    # Other lines should be of the form key=value.
    # XXX if they are not, we just append them right now.
    #
    my ($key,$val);
    if ($str =~ /^\s*([^=\s]+)\s*=\s*(.*)$/) {
	$key = $1;
	$val = $2;
    } else {
	push(@$aref, $str);
	return;
    }

    #
    # For key=value lines, look for existing instance, replacing as required.
    #
    my $found = 0;
    for (my $i = 0; $i < scalar(@$aref); $i++) {
	if ($aref->[$i] =~ /^\s*#/) {
	    next;
	}
	if ($aref->[$i] =~ /^\s*([^=\s]+)\s*=\s*(.*)$/) {
	    my $ckey = $1;
	    my $cval = $2;
	    if ($ckey eq $key) {
		if ($overwrite && $cval ne $val) {
		    $aref->[$i] = $str;
		    $vninfo->{'cfchanged'} = 1;
		}
		return;
	    }
	}
    }

    #
    # Not found, add it to the end
    #
    push(@$aref, $str);
    $vninfo->{'cfchanged'} = 1;
}

sub readXenConfig($)
{
    my ($config) = @_;
    my @cflines = ();

    if (!open(CF, "<$config")) {
	return undef;
    }
    while (<CF>) {
	chomp;
	push(@cflines, "$_");
    }
    close(CF);

    return \@cflines;
}

sub createXenConfig($$)
{
    my ($config,$lines) = @_;

    mkpath([dirname($config)]);
    if (!open(CF, ">$config")) {
	print STDERR "libvnode_xen: could not create $config\n";
	return -1;
    }
    foreach (@$lines) {
	print CF "$_\n";
    }

    close(CF);
    return 0;
}

sub lookupXenConfig($$)
{
    my ($aref, $key) = @_;

    #
    # Look for key=value.
    #
    for (my $i = 0; $i < scalar(@$aref); $i++) {
	if ($aref->[$i] =~ /^\s*#/) {
	    next;
	}
	if ($aref->[$i] =~ /^\s*([^=\s]+)\s*=\s*(.*)$/) {
	    my $ckey = $1;
	    my $cval = $2;
	    if ($ckey eq $key) {
		return $cval;
	    }
	}
    }
    return undef;
}

sub parseXenDiskInfo($$)
{
    my ($vnode_id, $aref) = @_;
    my $disks = {};

    #
    # Find the disk info and process the stanzas.
    #
    my $stanzas = lookupXenConfig($aref, "disk");
    if (!defined($stanzas)) {
	# No way to clean up from this. Gack.
	print STDERR "xen_vnodeCreate: Cannot find disk stanza in config\n";
	return undef
    }
    my $disklist = eval $stanzas;
    foreach my $disk (@$disklist) {
	if ($disk =~ /^phy:([^,]*),([^,]*)/) {
	    my $device = $1;
	    my $vndisk = $2;
	    # Need to pull out the lvm name from the device path.
	    my $lvname = basename($device);
		
	    # The root disk is marked by sda, xvda or hda.
	    if ($2 eq "sda" || $2 eq "xvda" || $2 eq "hda") {
		$disks->{$vnode_id} = [$lvname, $device, $vndisk];
	    }
	    else {
		$disks->{$lvname} = [$lvname, $device, $vndisk];
	    }
	}
	else {
	    print STDERR "Cannot parse disk: $disk\n";
	    return undef;
	}
    }
    return $disks;
}

#
# Mike's replacements for Jon's Xen python-class-using code.
#
# Nothing personal, just that code used an external shell script which used
# an external python class which used an LVM shared library which comes from
# who knows where--all of which made me nervous.
#

#
# Return size of volume group in (decimal, aka disk-manufactuer) GB.
#
sub lvmVGSize($)
{
    my ($vg) = @_;

    my $size = `vgs --noheadings -o size $vg`;
    if ($size =~ /(\d+\.\d+)([mgt])/i) {
	$size = $1;
	my $u = lc($2);
	if ($u eq "m") {
	    $size /= 1000;
	} elsif ($u eq "t") {
	    $size *= 1000;
	}
	return $size;
    }
    die "libvnode_xen: cannot parse LVM volume group size";
}

sub lvmVolumePath($)
{
    my ($name) = @_;
    return "/dev/$VGNAME/$name";
}

sub findLVMLogicalVolume($)
{
    my ($lvm)  = @_;
    my $lvpath = lvmVolumePath($lvm);
    my $exists = `lvs --noheadings -o origin $lvpath > /dev/null 2>&1`;
    return 0
	if ($?);

    return 1;
}

#
# Return the LVM that the indicated one is a snapshot of, or a null
# string if none.
#
sub findLVMOrigin($)
{
    my ($lv) = @_;

    foreach (`lvs --noheadings -o name,origin $VGNAME`) {
	if (/^\s*${lv}\s+(\S+)\s*$/) {
	    return $1;	
	}
    }
    return "";
}

#
# Rename or GC an image lvm. We can collect the lvm if there are no
# other lvms based on it.
#
sub GClvm($)
{
    my ($image)  = @_;
    my $oldest   = 0;
    my $inuse    = 0;
    my $found    = 0;

    if (! open(LVS, "lvs --noheadings -o lv_name,origin $VGNAME |")) {
	print STDERR "Could not start lvs\n";
	return -1;
    }
    while (<LVS>) {
	my $line = $_;
	my $imname;
	my $origin;
	
	if ($line =~ /^\s*([-\w\.\+]+)\s*$/) {
	    $imname = $1;
	}
	elsif ($line =~ /^\s*([-\w\.\+]+)\s+([-\w\.]+)$/) {
	    $imname = $1;
	    $origin = $2;
	}
	else {
	    print STDERR "Unknown line from lvs: $line\n";
	    return -1;
	}
	#print "$imname";
	#print " : $origin" if (defined($origin));
	#print "\n";

	# The exact image we are trying to GC.
	$found = 1
	    if ($imname eq $image);

	# If the origin is the image we are looking for,
	# then we mark it as inuse.
	$inuse = 1
	    if (defined($origin) && $origin eq $image);

	# We want to find the highest numbered backup for this image.
	# Might not be any of course.
	if ($imname =~ /^([-\w]+)\.(\d+)$/) {
	    $oldest = $2
		if ($1 eq $image && $2 > $oldest);
	}
    }
    close(LVS);
    return -1
	if ($?);
    print "found:$found, inuse:$inuse, oldest:$oldest\n";
    if (!$found) {
	print STDERR "GClvm($image): no such lvm found\n";
	return -1;
    }
    if (!$inuse) {
	print "GClvm($image): not in use; deleting\n";
 	mysystem2("lvremove -f /dev/$VGNAME/$image");
	return -1
	    if ($?);
	return 0;
    }
    $oldest++;
    # rename nicely works even when snapshots exist
    mysystem2("lvrename /dev/$VGNAME/$image /dev/$VGNAME/$image.$oldest");
    return -1
	if ($?);
    
    return 0;
}

#
# Deal with IFBs.
#
#
# Deal with IFBs.
#
sub AllocateIFBs($$$)
{
    my ($vmid, $node_lds, $private) = @_;
    my @ifbs = ();

    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 1800) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global lock after a long time!\n";
	return -1;
    }

    my %MDB;
    if (!dbmopen(%MDB, $IFBDB, 0660)) {
	print STDERR "*** Could not create $IFBDB\n";
	TBScriptUnlock();
	return undef;
    }

    #
    # We need an IFB for every ld, so just make sure we can get that many.
    #
    my $needed = scalar(@$node_lds);

    #
    # First pass, look for enough before actually allocating them.
    #
    my $i = 0;
    my $n = $needed;
    
    while ($n && $i < $MAXIFB) {
	if (!defined($MDB{"$i"}) || $MDB{"$i"} eq "" || $MDB{"$i"} eq "$vmid") {
	    $n--;
	}
	$i++;
    }
    if ($i == $MAXIFB || $n) {
	print STDERR "*** No more IFBs\n";
	dbmclose(%MDB);
	TBScriptUnlock();
	return undef;
    }
    #
    # Now allocate them.
    #
    $i = 0;
    $n = $needed;
    
    while ($n && $i < $MAXIFB) {
	if (!defined($MDB{"$i"}) || $MDB{"$i"} eq "" || $MDB{"$i"} eq "$vmid") {
	    $MDB{"$i"} = $vmid;
	    # Record ifb in use
	    $private->{'ifbs'}->{$i} = $i;
	    push(@ifbs, $i);
	    $n--;
	}
	$i++;
    }
    dbmclose(%MDB);
    TBScriptUnlock();
    return \@ifbs;
}

sub ReleaseIFBs($$)
{
    my ($vmid, $private) = @_;
    
    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 1800) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global lock after a long time!\n";
	return -1;
    }
    my %MDB;
    if (!dbmopen(%MDB, $IFBDB, 0660)) {
	print STDERR "*** Could not create $IFBDB\n";
	TBScriptUnlock();
	return -1;
    }
    #
    # Do not worry about what we think we have, just make sure we
    # have released everything assigned to this vmid. 
    #
    for (my $i = 0; $i < $MAXIFB; $i++) {
	if (defined($MDB{"$i"}) && $MDB{"$i"} eq "$vmid") {
	    $MDB{"$i"} = "";
	}
    }
    dbmclose(%MDB);
    TBScriptUnlock();
    delete($private->{'ifbs'});
    return 0;
}

#
# See if a route table already exists for the given tag, and if not,
# allocate it and return the table number.
#
sub AllocateRouteTable($)
{
    my ($token) = @_;
    my $rval = undef;

    if (! -e $RTDB && InitializeRouteTables()) {
	print STDERR "*** Could not initialize routing table DB\n";
	return undef;
    }
    my %RTDB;
    if (!dbmopen(%RTDB, $RTDB, 0660)) {
	print STDERR "*** Could not open $RTDB\n";
	return undef;
    }
    # Look for existing.
    for (my $i = 1; $i < $MAXROUTETTABLE; $i++) {
	if ($RTDB{"$i"} eq $token) {
	    $rval = $i;
	    print STDERR "Found routetable $i ($token)\n";
	    goto done;
	}
    }
    # Allocate a new one.
    for (my $i = 1; $i < $MAXROUTETTABLE; $i++) {
	if ($RTDB{"$i"} eq "") {
	    $RTDB{"$i"} = $token;
	    print STDERR "Allocate routetable $i ($token)\n";
	    $rval = $i;
	    goto done;
	}
    }
  done:
    dbmclose(%RTDB);
    return $rval;
}

sub LookupRouteTable($)
{
    my ($token) = @_;
    my $rval = undef;

    my %RTDB;
    if (!dbmopen(%RTDB, $RTDB, 0660)) {
	print STDERR "*** Could not open $RTDB\n";
	return undef;
    }
    # Look for existing.
    for (my $i = 1; $i < $MAXROUTETTABLE; $i++) {
	if ($RTDB{"$i"} eq $token) {
	    $rval = $i;
	    goto done;
	}
    }
  done:
    dbmclose(%RTDB);
    return $rval;
}

sub FreeRouteTable($)
{
    my ($token) = @_;
    
    my %RTDB;
    if (!dbmopen(%RTDB, $RTDB, 0660)) {
	print STDERR "*** Could not open $RTDB\n";
	return -1;
    }
    # Look for existing.
    for (my $i = 1; $i < $MAXROUTETTABLE; $i++) {
	if ($RTDB{"$i"} eq $token) {
	    $RTDB{"$i"} = "";
	    print STDERR "Free routetable $i ($token)\n";
	    last;
	}
    }
    dbmclose(%RTDB);
    return 0;
}

sub InitializeRouteTables()
{
    # Create clean route table DB and seed it with defaults.
    my %RTDB;
    if (!dbmopen(%RTDB, $RTDB, 0660)) {
	print STDERR "*** Could not create $RTDB\n";
	return -1;
    }
    # Clear all,
    for (my $i = 0; $i < $MAXROUTETTABLE; $i++) {
	$RTDB{"$i"} = ""
	    if (!defined($RTDB{"$i"}));
    }
    # Seed the reserved tables.
    if (! open(RT, $RTTABLES)) {
	print STDERR "*** Could not open $RTTABLES\n";
	return -1;
    }
    while (<RT>) {
	if ($_ =~ /^(\d*)\s*/) {
	    $RTDB{"$1"} = "$1";
	}
    }
    close(RT);
    dbmclose(%RTDB);
    return 0;
}

sub ReleaseRouteTables($$)
{
    my ($vmid, $private) = @_;
    
    if (TBScriptLock($GLOBAL_CONF_LOCK, 0, 1800) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the global lock after a long time!\n";
	return -1;
    }
    if (exists($private->{'routetables'})) {
	foreach my $token (keys(%{ $private->{'routetables'} })) {
	    if (FreeRouteTable($token) < 0) {
		TBScriptUnlock();
		return -1;
	    }
	    delete($private->{'routetables'}->{$token});
	}
    }

    TBScriptUnlock();
    return 0;
}

#
# Look inside a disk image and try to find the default kernel and
# ramdisk to boot. This should work for most of our standard images.
# Note that we use our own lightly hacked version of pygrub, that
# can look inside our images, and can hand simple submenus properly.
#
sub ExtractKernelFromLinuxImage($$)
{
    my ($lvname, $outdir) = @_;
    my $lvmpath = lvmVolumePath($lvname);
    my $PYGRUB  = "$BINDIR/pygrub";

    #
    # Not sure what is going here; pygrub sometimes heads off into
    # inifinity, looping and using 100% CPU. So, lets put a timer
    # on it.
    #
    my $childpid = fork();
    if ($childpid) {
	local $SIG{ALRM} = sub { kill("TERM", $childpid); };
	alarm 60;
	waitpid($childpid, 0);
	my $stat = $?;
	alarm 0;

	if ($stat) {
	    print STDERR "pygrub returned $stat ... \n";
	    return ();
	}
	return ("$outdir/kernel", "$outdir/ramdisk");	
    }
    else {
	#
	# We have blocked most signals in mkvnode, including TERM.
	# Temporarily unblock and set to default so we die. 
	#
	local $SIG{TERM} = 'DEFAULT';
	exec("$PYGRUB --quiet --output-format=simple ".
	      "--output-directory=$outdir $lvmpath");
	exit(1);
    }
}

sub ExtractKernelFromFreeBSDImage($$$)
{
    my ($lvname, $lvmpath, $outdir) = @_;
    my $mntpath = "/mnt/$lvname";
    my $kernel  = undef;
    my $mbrboot = undef;

    return undef
	if (! -e $mntpath && mysystem2("mkdir -p $mntpath"));

    mysystem2("mount -t ufs -o ro,ufstype=44bsd $lvmpath $mntpath");
    if ($?) {
	# try UFS2
	mysystem2("mount -t ufs -o ro,ufstype=ufs2 $lvmpath $mntpath");
    }
    return undef
	if ($?);

    if (-e "$mntpath/boot/kernel/kernel" ||
	-e "$mntpath/boot/kernel.xen/kernel") {
	#
	# Use XEN kernel if it exists; Mike says he will start putting this
	# kernel into our FBSD images. 
	#
	my $kernelfile;

	if (-e "$mntpath/boot/kernel.xen/kernel") {
	    $kernelfile = "$mntpath/boot/kernel.xen/kernel";
	}
	else {
	    $kernelfile = "$mntpath/boot/kernel/kernel";

	    #
	    # See if there is a xen section. If not, then we cannot use it.
	    #
	    mysystem2("nm $kernelfile | grep -q xen_guest");
	    if ($?) {
		# XXX PVHVM kernel
		mysystem2("nm $kernelfile | grep -q xen_hvm_init");
	    }
	    goto skip
		if ($?);
	}
	mysystem2("/bin/cp -pf $kernelfile $outdir/kernel");
	goto skip
	    if ($?);
	$kernel = "$outdir/kernel";
    }

    #
    # Extract the boot0 code for HVM boots.
    #
    if (-e "$mntpath/boot/boot0") {
	my $bootfile = "$mntpath/boot/boot0";

	mysystem2("/bin/cp -pf $bootfile $outdir/boot0");
	goto skip
	    if ($?);
    }

  skip:
    mysystem2("umount $mntpath");
    return undef
	if ($?);
    return $kernel;
}

#
# Store and Load the image metadata (loadinfo data).
#
sub StoreImageMetadata($$)
{
    my ($imagename, $metadata) = @_;
    my $metapath = "$METAFS/${imagename}.metadata";

    if (!open(META, ">$metapath")) {
	print STDERR "libvnode_xen: could not create $metapath\n";
	return -1;
    }
    foreach my $key (keys(%{$metadata})) {
	my $val = $metadata->{$key};
	print META "${key}=${val}\n";
    }
    close(META);
    return 0;
}
sub LoadImageMetadata($$)
{
    my ($imagename, $metadata) = @_;
    my $metapath = "$METAFS/${imagename}.metadata";
    my %result;

    if (!open(META, "$metapath")) {
	print STDERR "libvnode_xen: could not open $metapath\n";
	return -1;
    }
    while (<META>) {
	if ($_ =~ /^([-\w]*)\s*=\s*(.*)$/) {
	    my $key = $1;
	    my $val = $2;
	    $result{$key} = "$val";
	}
    }
    close(META);
    $result{'IMAGENAME'} = $imagename;
    $$metadata = \%result;
    return 0;
}

#
# Fix up the initramfs so that it loads the xen-blkfront driver.
# This is really stupid and appears to be necessary on ubuntu.
#
sub FixRamFs($$)
{
    my ($vnode_id, $ramfspath)  = @_;
    my $tempdir = "$EXTRAFS/$vnode_id/ramfs";
    my $modules = "$EXTRAFS/$vnode_id/ramfs/conf/modules";
    my $rval    = 0;

    return -1
	if (-e $tempdir && mysystem2("/bin/rm -rf $tempdir"));

    return -1
	if (mysystem2("mkdir -p $tempdir"));

    return -1
	if (mysystem2("cd $tempdir; zcat $ramfspath | cpio -i"));
    
    #
    # If there is a modules file, and it does not include the
    # the xen-blkfront module, add it. Then pack it back up and
    # copy back into place.
    #
    if (-e $modules) {
	if (mysystem2("grep -q xen-blkfront $modules") == 0) {
	    # Tell caller ramfs was okay. 
	    $rval = 1;
	    goto done;
	}
    }
    mysystem2("echo 'xen-blkfront' >> $modules");
    mysystem2("cd $tempdir; find . | cpio -H newc -o | gzip > $ramfspath");
    return -1
	if ($?);
done:
    mysystem2("/bin/rm -rf $tempdir");
    return $rval;
}

#
# Helper function to run a shell command wrapped by a lock.
#
sub RunWithLock($$)
{
    my ($token, $command) = @_;
    my $lockref;

    if (TBScriptLock($token, undef, 900, \$lockref) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get $token lock after a long time!\n";
	return -1;
    }
    mysystem2($command);
    my $status = $?;
    sleep(1);

    TBScriptUnlock($lockref);
    return $status;
}

#
# We need to control how many simultaneous creates happen at once.
#
my $createvnode_lockref;

sub CreateVnodeLock()
{
    my $tries = 1000;
    
    while ($tries) {
	for (my $i = 0; $i < 3; $i++) {
	    my $token  = "createvnode_${i}";
	    my $locked = TBScriptLock($token, TBSCRIPTLOCK_NONBLOCKING(),
				      0, \$createvnode_lockref);

	    return 0
		if ($locked == TBSCRIPTLOCK_OKAY());
	    return -1
		if ($locked == TBSCRIPTLOCK_FAILED());
	}
	print "Still trying to get the create lock at " . time() . "\n"
	    if (($tries % 60) == 0);
	sleep(4);
	$tries--;
    }
    print STDERR "Could not get the createvnode lock after a long time!\n";
    return -1;
}

sub CreateVnodeUnlock()
{
    TBScriptUnlock($createvnode_lockref);
}

1;
