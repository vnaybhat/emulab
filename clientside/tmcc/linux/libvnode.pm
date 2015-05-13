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
# General vnode setup routines and helpers (Linux)
#
package libvnode;
use Exporter;
@ISA    = "Exporter";
@EXPORT = qw( makeIfaceMaps makeBridgeMaps
	      findControlNet existsIface findIface findMac
	      existsBridge findBridge findBridgeIfaces
              downloadImage getKernelVersion createExtraFS
              forwardPort removePortForward lvSize DoIPtables restartDHCP
            );

use Data::Dumper;
use libutil;
use libgenvnode;
use libsetup;
use libtestbed;

#
# Magic control network config parameters.
#
my $PCNET_IP_FILE   = "/var/emulab/boot/myip";
my $PCNET_MASK_FILE = "/var/emulab/boot/mynetmask";
my $PCNET_GW_FILE   = "/var/emulab/boot/routerip";

# Other local constants
my $IPTABLES   = "/sbin/iptables";

my $debug = 0;

sub setDebug($) {
    $debug = shift;
    print "libvnode: debug=$debug\n"
	if ($debug);
}

#
# Setup (or teardown) a port forward according to input hash containing:
# * ext_ip:   External IP address traffic is destined to
# * ext_port: External port traffic is destined to
# * int_ip:   Internal IP address traffic is redirected to
# * int_port: Internal port traffic is redirected to
#
# 'protocol' - a string; either "tcp" or "udp"
# 'remove'   - a boolean indicating whether or not to do a teardown.
#
# Side effect: uses iptables command to manipulate NAT.
#
sub forwardPort($;$) {
    my ($ref, $remove) = @_;
    
    my $int_ip   = $ref->{'int_ip'};
    my $ext_ip   = $ref->{'ext_ip'};
    my $int_port = $ref->{'int_port'};
    my $ext_port = $ref->{'ext_port'};
    my $protocol = $ref->{'protocol'};

    if (!(defined($int_ip) && 
	  defined($ext_ip) && 
	  defined($int_port) &&
	  defined($ext_port) && 
	  defined($protocol))
	) {
	print STDERR "WARNING: forwardPort: parameters missing!";
	return -1;
    }

    if ($protocol !~ /^(tcp|udp)$/) {
	print STDERR "WARNING: forwardPort: Unknown protocol: $protocol\n";
	return -1;
    }
    
    # Are we removing or adding the rule?
    my $op = (defined($remove) && $remove) ? "D" : "A";

    return -1
	if (DoIPtables("-v -t nat -$op PREROUTING -p $protocol -d $ext_ip ".
		       "--dport $ext_port -j DNAT ".
		       "--to-destination $int_ip:$int_port"));
    return 0;
}

#
# Oh jeez, iptables is about the dumbest POS I've ever seen; it fails
# if you run two at the same time. So we have to serialize the calls.
# The problem is that XEN also manipulates things, and so it is hard
# to get a perfect lock. So, we do our best and if it fails sleep for
# a couple of seconds and try again. 
#
sub DoIPtables(@)
{
    my (@rules) = @_;

    if (TBScriptLock("iptables", 0, 900) != TBSCRIPTLOCK_OKAY()) {
	print STDERR "Could not get the iptables lock after a long time!\n";
	return -1;
    }
    foreach my $rule (@rules) {
	my $retries = 5;
	my $status  = 0;
	while ($retries > 0) {
	    mysystem2("$IPTABLES $rule");
	    $status = $?;
	    last
		if (!$status || $status >> 8 != 4);
	    print STDERR "will retry in a couple of seconds ...\n";
	    sleep(2);
	    $retries--;
	}
	# Operation failed - return error
	if (!$retries || $status) {
	    TBScriptUnlock();
	    return -1;
	}
    }
    TBScriptUnlock();
    return 0;
}

sub removePortForward($) {
    my $ref = shift;
    return forwardPort($ref,1);
}

#
# A spare disk or disk partition is one whose partition ID is 0 and is not
# mounted and is not in /etc/fstab AND is >= the specified minsize (in MiB).
# Yes, this means it's possible that we might steal partitions that are
# in /etc/fstab by UUID -- oh well.
#
# This function returns a hash of:
#   device name => part number => {size,path}
# where size is in bytes and path is the full device name path to use
# (which may NOT just be a simple concatonation of device name and partition).
# Note that a device name => {size,fullpath} entry is filled IF the device
# has no partitions.
#
sub findSpareDisks($) {
    my ($minsize) = @_;

    my %retval = ();
    my %mounts = ();
    my %ftents = ();
    my %pvs = ();

    # /proc/partitions prints sizes in 1K phys blocks
    my $BLKSIZE = 1024;

    # convert minsize to 1K blocks
    $minsize *= 1024;

    open (MFD,"/proc/mounts") 
	or die "open(/proc/mounts): $!";
    while (my $line = <MFD>) {
	chomp($line);
	if ($line =~ /^([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+([^\s]+)\s+/) {
	    $mounts{$1} = $2;
	}
    }
    close(MFD);

    open (FFD,"/etc/fstab") 
	or die "open(/etc/fstab): $!";
    while (my $line = <FFD>) {
	chomp($line);
	if ($line =~ /^([^\s]+)\s+([^\s]+)/) {
	    $ftents{$1} = $2;
	}
    }
    close(FFD);

    if (-x "/sbin/pvs" && open (PFD,"/sbin/pvs|")) {
	while (my $line = <PFD>) {
	    chomp($line);
	    if ($line =~ /^\s*\/dev\/(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+/) {
		$pvs{$1} = 1;
	    }
	}
	close(PFD);
    }

    open (PFD,"/proc/partitions") 
	or die "open(/proc/partitions): $!";
    while (my $line = <PFD>) {
	chomp($line);

	# ignore malformed lines
	my ($size,$devpart);
	if ($line =~ /^\s*\d+\s+\d+\s+(\d+)\s+(\S+)$/) {
	    $size = $1;
	    $devpart = $2;
	} else {
	    next;
	}

	#
	# XXX weed out special cases:
	#    SCSI CDROM (srN),
	#    device mapper files (dm-N),
	#    LVM PVs
	#
	if ($devpart =~ /^sr\d+$/ ||
	    $devpart =~ /^dm-\d+$/ ||
	    exists($pvs{$devpart})) {
	    next;
	}

	#
	# The old heuristic was: if it ends in a digit, it is a partition
	# device otherwise it is a disk device. But that got screwed up by,
	# e.g., the cciss device where "c0d0" is a disk while "c0d0p1" is a
	# partition. The new fallible heuristic is: if it ends in a digit
	# but is of the form cNdN then it is a disk!
	#
	if ($devpart =~ /^(\S+)(\d+)$/) {
	    my ($dev,$part) = ($1,$2);

	    # cNdN(pN) format
	    if ($devpart =~ /(.*c\d+d\d+)(p\d+)?$/) {
		if (!defined($2)) {
		    goto isdisk;
		}
		$dev = $1;
	    }

	    # XXX don't include extended partitions (the reason is to filter
	    # out pseudo partitions that linux creates for bsd disklabel 
	    # slices -- we don't want to use those!
	    # 
	    # (of course, a much better approach would be to check if a 
	    # partition is contained within another and not use it.)
	    next 
		if ($part > 4);

	    # This is a partition on an earlier discovered disk device,
	    # ignore the disk device.
	    if (exists($retval{$dev}{"size"})) {
		delete $retval{$dev}{"size"};
		delete $retval{$dev}{"path"};
		if (scalar(keys(%{$retval{$dev}})) == 0) {
		    delete $retval{$dev};
		}
	    }
	    if (!defined($mounts{"/dev/$devpart"}) 
		&& !defined($ftents{"/dev/$devpart"})) {

		# try checking its ext2 label
		my @outlines = `dumpe2fs -h /dev/$devpart 2>&1`;
		if (!$?) {
		    my ($uuid,$label);
		    foreach my $line (@outlines) {
			if ($line =~ /^Filesystem UUID:\s+([-\w\d]+)/) {
			    $uuid = $1;
			}
			elsif ($line =~ /^Filesystem volume name:\s+([-\/\w\d]+)/) {
			    $label = $1;
			}
		    }
		    if ((defined($uuid) && defined($ftents{"UUID=$uuid"}))
			|| (defined($label) && defined($ftents{"LABEL=$label"})
			    && $ftents{"LABEL=$label"} eq $label)) {
			next;
		    }
		}

		# one final check: partition id
		my $output = `sfdisk --print-id /dev/$dev $part 2>/dev/null`;
		chomp($output);
		if ($?) {
		    print STDERR "WARNING: findSpareDisks: error running 'sfdisk --print-id /dev/$dev $part': $! ... ignoring /dev/$devpart\n";
		}
		elsif ($output eq "0" && $size >= $minsize) {
		    $retval{$dev}{$part}{"size"} = $BLKSIZE * $size;
		    $retval{$dev}{$part}{"path"} = "/dev/$devpart";
		}
	    }
	}
	else {
isdisk:
	    if (!defined($mounts{"/dev/$devpart"}) &&
		!defined($ftents{"/dev/$devpart"}) &&
		$size >= $minsize) {
		$retval{$devpart}{"size"} = $BLKSIZE * $size;
		$retval{$devpart}{"path"} = "/dev/$devpart";
	    }
	}
    }
    foreach my $k (keys(%retval)) {
	if (scalar(keys(%{$retval{$k}})) == 0) {
	    delete $retval{$k};
	}
    }
    close(PFD);

    return %retval;
}

my %if2mac = ();
my %mac2if = ();
my %ip2if = ();
my %ip2mask = ();
my %ip2net = ();
my %ip2maskbits = ();

#
# Grab iface, mac, IP info from /sys and /sbin/ip.
#
sub makeIfaceMaps()
{
    # clean out anything
    %if2mac = ();
    %mac2if = ();
    %ip2if = ();
    %ip2net = ();
    %ip2mask = ();
    %ip2maskbits = ();

    my $devdir = '/sys/class/net';
    opendir(SD,$devdir) 
	or die "could not find $devdir!";
    my @ifs = grep { /^[^\.]/ && -f "$devdir/$_/address" } readdir(SD);
    closedir(SD);

    foreach my $iface (@ifs) {
	next
	    if ($iface =~ /^ifb/ || $iface =~ /^imq/);
	
	if ($iface =~ /^([\w\d\-_]+)$/) {
	    $iface = $1;
	}
	else {
	    next;
	}

	open(FD,"/sys/class/net/$iface/address") 
	    or die "could not open /sys/class/net/$iface/address!";
	my $mac = <FD>;
	close(FD);
	next if (!defined($mac) || $mac eq '');

	$mac =~ s/://g;
	chomp($mac);
	$mac = lc($mac);
	$if2mac{$iface} = $mac;
	$mac2if{$mac} = $iface;

	# also find ip, ugh
	my $pip = `ip addr show dev $iface | grep 'inet '`;
	chomp($pip);
	if ($pip =~ /^\s+inet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/) {
	    my $ip = $1;
	    $ip2if{$ip} = $iface;
	    my @ip = split(/\./,$ip);
	    my $bits = int($2);
	    my @netmask = (0,0,0,0);
	    my ($idx,$counter) = (0,8);
	    for (my $i = $bits; $i > 0; --$i) {
		--$counter;
		$netmask[$idx] += 2 ** $counter;
		if ($counter == 0) {
		    $counter = 8;
		    ++$idx;
		}
	    }
	    my @network = ($ip[0] & $netmask[0],$ip[1] & $netmask[1],
			   $ip[2] & $netmask[2],$ip[3] & $netmask[3]);
	    $ip2net{$ip} = join('.',@network);
	    $ip2mask{$ip} = join('.',@netmask);
	    $ip2maskbits{$ip} = $bits;
	}
    }

    if ($debug > 1) {
	print STDERR "makeIfaceMaps:\n";
	print STDERR "if2mac:\n";
	print STDERR Dumper(%if2mac) . "\n";
	#print STDERR "mac2if:\n";
	#print STDERR Dumper(%mac2if) . "\n";
	print STDERR "ip2if:\n";
	print STDERR Dumper(%ip2if) . "\n";
	print STDERR "\n";
    }

    return 0;
}

#
# Find control net iface info.  Returns:
# (iface_name,IP,IPmask,IPmaskbits,IPnet,MAC,GW)
#
sub findControlNet()
{
    my $ip = (-r $PCNET_IP_FILE) ? `cat $PCNET_IP_FILE` : "0";
    chomp($ip);
    if ($ip =~ /^(\d+\.\d+\.\d+\.\d+)$/) {
	$ip = $1;
    } else {
	die "Could not find valid control net IP (no $PCNET_IP_FILE?)";
    }
    my $gw = (-r $PCNET_GW_FILE) ? `cat $PCNET_GW_FILE` : "0";
    chomp($gw);
    if ($gw =~ /^(\d+\.\d+\.\d+\.\d+)$/) {
	$gw = $1;
    } else {
	die "Could not find valid control net GW (no $PCNET_GW_FILE?)";
    }
    return ($ip2if{$ip}, $ip, $ip2mask{$ip}, $ip2maskbits{$ip}, $ip2net{$ip},
	    $if2mac{$ip2if{$ip}}, $gw);
}

sub existsIface($) {
    my $iface = shift;

    return 1
        if (exists($if2mac{$iface}));

    return 0;
}

sub findIface($) {
    my $mac = shift;

    $mac =~ s/://g;
    $mac = lc($mac);
    return $mac2if{$mac}
        if (exists($mac2if{$mac}));

    return undef;
}

sub findMac($) {
    my $iface = shift;

    return $if2mac{$iface}
        if (exists($if2mac{$iface}));

    return undef;
}

my %bridges = ();
my %if2br = ();

sub makeBridgeMaps() {
    # clean out anything...
    %bridges = ();
    %if2br = ();

    my @lines = `brctl show`;
    # always get rid of the first line -- it's the column header 
    shift(@lines);
    my $curbr = '';
    foreach my $line (@lines) {
	if ($line =~ /^([\w\d\-\.]+)\s+/) {
	    $curbr = $1;
	    $bridges{$curbr} = [];
	}
	if ($line =~ /^[^\s]+\s+[^\s]+\s+[^\s]+\s+([\w\d\-\.]+)$/ 
	    || $line =~ /^\s+([\w\d\-\.]+)$/) {
	    push @{$bridges{$curbr}}, $1;
	    $if2br{$1} = $curbr;
	}
    }

    if ($debug > 1) {
	print STDERR "makeBridgeMaps:\n";
	print STDERR "bridges:\n";
	print STDERR Dumper(%bridges) . "\n";
	print STDERR "if2br:\n";
	print STDERR Dumper(%if2br) . "\n";
	print STDERR "\n";
    }

    return 0;
}

sub existsBridge($) {
    my $bname = shift;

    return 1
        if (exists($bridges{$bname}));

    return 0;
}

sub findBridge($) {
    my $iface = shift;

    return $if2br{$iface}
        if (exists($if2br{$iface}));

    return undef;
}

sub findBridgeIfaces($) {
    my $bname = shift;

    return @{$bridges{$bname}}
        if (exists($bridges{$bname}));

    return undef;
}

#
# Since (some) vnodes are imageable now, we provide an image fetch
# mechanism.  Caller provides an imagepath for frisbee, and a hash of
# args that comes directly from loadinfo.
#
sub downloadImage($$$$) {
    my ($imagepath,$todisk,$nodeid,$reload_args_ref) = @_;

    return -1 
	if (!defined($imagepath) || !defined($reload_args_ref));

    my $addr = $reload_args_ref->{"ADDR"};
    my $FRISBEE = "/usr/local/bin/frisbee";
    my $IMAGEUNZIP = "/usr/local/bin/imageunzip";
    my $command = "";
    # Backwards compat.
    if (! -e $FRISBEE) {
	$FRISBEE = "/usr/local/etc/emulab/frisbee";
    }

    if (!defined($addr) || $addr eq "") {
	# frisbee master server world
	my ($server, $imageid);
	my $proxyopt  = "";
	my $todiskopt = "";

	if ($reload_args_ref->{"SERVER"} =~ /^(\d+\.\d+\.\d+\.\d+)$/) {
	    $server = $1;
	}
	if ($reload_args_ref->{"IMAGEID"} =~
	    /^([-\d\w]+),([-\d\w]+),([-\d\w\.:]+)$/) {
	    $imageid = "$1/$3";
	}
	if (SHAREDHOST()) {
	    $proxyopt = "-P $nodeid";
	}
	if (!$todisk) {
	    $todiskopt = "-N";
	}
	if ($server && $imageid) {
	    $command = "$FRISBEE -f -M 64 $proxyopt $todiskopt ".
		"         -S $server -B 30 -F $imageid $imagepath";
	}
	else {
	    print STDERR "Could not parse frisbee loadinfo\n";
	    return -1;
	}
    }
    elsif ($addr =~/^(\d+\.\d+\.\d+\.\d+):(\d+)$/) {
	my $mcastaddr = $1;
	my $mcastport = $2;

	$command = "$FRISBEE -f -M 64 -m $mcastaddr -p $mcastport $imagepath";
    }
    elsif ($addr =~ /^http/) {
	if ($todisk) {
	    $command = "wget -nv -N -O - '$addr' | ".
		"$IMAGEUNZIP -f -W 32 - $imagepath";
	}
	else {
	    $command = "wget -nv -N -O $imagepath '$addr'";
	}
    }
    print STDERR $command . "\n";
    
    #
    # Run the command protected by an alarm to avoid trying forever,
    # as frisbee is prone to doing.
    #
    my $childpid = fork();
    if ($childpid) {
	local $SIG{ALRM} = sub { kill("TERM", $childpid); };
	alarm 60 * 30;
	waitpid($childpid, 0);
	my $stat = $?;
	alarm 0;

	if ($stat) {
	    print STDERR "  returned $stat ... \n";
	    return -1;
	}
	return 0;
    }
    else {
	#
	# We have blocked most signals in mkvnode, including TERM.
	#
	local $SIG{TERM} = 'DEFAULT';
	exec($command);
	exit(1);
    }
}

#
# Get kernel (major,minor,patchlevel) version tuple.
#
sub getKernelVersion()
{
    my $kernvers = `cat /proc/sys/kernel/osrelease`;
    chomp $kernvers;

    if ($kernvers =~ /^(\d+)\.(\d+)\.(\d+)/) {
	return ($1,$2,$3);
    }

    return undef;
}

#
# Create an extra FS using an LVM.
#
sub createExtraFS($$$)
{
    my ($path, $vgname, $size) = @_;
    
    if (! -e $path) {
	system("mkdir $path") == 0
	    or return -1;
    }
    return 0
	if (-e "$path/.mounted");
    
    my $lvname;
    if ($path =~ /\/(.*)$/) {
	$lvname = $1;
    }
    my $lvpath = "/dev/$vgname/$lvname";
    my $exists = `lvs --noheadings -o origin $lvpath > /dev/null 2>&1`;
    if ($?) {
	system("lvcreate -n $lvname -L $size $vgname") == 0
	    or return -1;

	system("mke2fs -j -q $lvpath") == 0
	    or return -1;
    }
    if (! -e "$path/.mounted") {
	system("mount $lvpath $path") == 0
	    or return -1;
    }
    system("touch $path/.mounted");

    if (system("egrep -q -s '^${lvpath}' /etc/fstab")) {
	system("echo '$lvpath $path ext3 defaults 0 0' >> /etc/fstab")
	    == 0 or return -1;
    }
    return 0;
}

#
# Figure out the size of the LVM.
#
sub lvSize($)
{
    my ($device) = @_;
    
    my $lv_size = `lvs -o lv_size --noheadings --units k --nosuffix $device`;
    return undef
	if ($?);
    
    chomp($lv_size);
    $lv_size =~ s/^\s+//;
    $lv_size =~ s/\s+$//;
    return $lv_size;
}

sub restartDHCP()
{
    my $dhcpd_service = 'dhcpd';
    if (-f '/etc/init/isc-dhcp-server.conf') {
        $dhcpd_service = 'isc-dhcp-server';
    }

    # make sure dhcpd is running
    if (-x '/sbin/initctl') {
        # Upstart
        if (mysystem2("/sbin/initctl restart $dhcpd_service") != 0) {
            mysystem2("/sbin/initctl start $dhcpd_service");
        }
    } else {
        #sysvinit
        mysystem2("/etc/init.d/$dhcpd_service restart");
    }
}

#
# Life's a rich picnic.  And all that.
1;
