#!/usr/bin/perl -w
#
# Copyright (c) 2000-2013 University of Utah and the Flux Group.
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
use English;
use Getopt::Std;
use Fcntl;
use IO::Handle;
use Socket;

# Drag in path stuff so we can find emulab stuff.
BEGIN { require "/etc/emulab/paths.pm"; import emulabpaths; }
my $DOSTYPE = "$BINDIR/dostype";

sub mysystem($);

sub usage()
{
    print("Usage: mkextrafs.pl [-fq] [-s slice] [-lM] [-v <vglist>] [-m <lvlist>] [-z <lvsize>] [-r disk] <mountpoint>\n");
    exit(-1);
}
my  $optlist = "fqls:v:Mm:z:r:";

#
# Yep, hardwired for now.  Should be options or queried via TMCC.
#
my $disk       = "hda";
my $slice      = "4";
my $partition  = "";
my $diskopt;

my $forceit    = 0;
my $quiet      = 0;

my $lvm        = 0;
my @vglist     = ();
my @lvlist     = ();
my $lmonster   = 0;

#
# Turn off line buffering on output
#
STDOUT->autoflush(1);
STDERR->autoflush(1);

#
# Untaint the environment.
# 
$ENV{'PATH'} = "/tmp:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:".
    "/usr/local/bin:/usr/site/bin:/usr/site/sbin:/usr/local/etc/emulab";
delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};

#
# Parse command arguments. Once we return from getopts, all that should be
# left are the required arguments.
#
%options = ();
if (! getopts($optlist, \%options)) {
    usage();
}
if (defined($options{"f"})) {
    $forceit = 1;
}
if (defined($options{"q"})) {
    $quiet = 1;
}
if (defined($options{"r"})) {
    $diskopt = $options{"r"};
}
if (defined($options{"s"})) {
    $slice = $options{"s"};
}
if (defined($options{"l"})) {
    $lvm = 1;
}
if (defined($options{"v"})) {
    @vglist = split(/,/,$options{"v"});
}
if (defined($options{"m"})) {
    @lvlist = split(/,/,$options{"m"});
}
if (defined($options{"z"})) {
    @sizelist = split(/,/,$options{"z"});
}
if (defined($options{"M"})) {
    $lmonster = 1;
    if (@vglist > 1 || @lvlist > 1) {
	die("*** $0:\n".
	    "    If you want a single giant LVM-based filesystem, you can" . 
	    "    only specify a single volume group and logical volume!\n");
    }
}
if (scalar(@vglist) == 0) {
    @vglist = ('emulab',);
}
if (scalar(@lvlist) == 0) {
    @lvlist = ('emulab',);
}
if (scalar(@sizelist) == 0) {
    @sizelist = ('0',);
}
if (@vglist > 1 && @lvlist > 1) {
	die("*** $0:\n".
	    "    You cannot specify multiple volume groups and logical volumes!\n");
}
if (scalar(@lvlist) != scalar(@sizelist)) {
	die("*** $0:\n".
            "    Some of the lvm vols have no size specified in the -z list." .
	    "	 If you do not want any particular size then specify 0 instead.\n");
}

my $mountpoint;
if (!$lvm || ($lvm && $lmonster)) {
    if (@ARGV != 1) {
	usage();
    }
    $mountpoint  = $ARGV[0];
    
    if (! -d $mountpoint) {
	die("*** $0:\n".
	    "    $mountpoint does not exist!\n");
    }
}

#
# XXX determine the disk based on the root fs.
# Note: 'rootfs' grep is because Fedora 15 df shows two lines for "/" 
#
if (defined($diskopt)) {
    $disk = $diskopt;
    $disk =~ s/^\/dev\///;
}
else {
    my $rootdev = `df | egrep '/\$' | grep -v rootfs`;
    if ($rootdev =~ /^\/dev\/([a-z]+)\d+\s+/) {
	$disk = $1;
    }
}

my $diskdev    = "/dev/${disk}";
my $fsdevice   = "${diskdev}${slice}";

#
# For LVM, just exit if the physical volume already exists
#
if ($lvm) {
    my @out = `pvs --noheadings 2>&1`;
    if (grep(/^\s+$fsdevice\s+/, @out)) {
	if ($quiet) {
	    exit(0);
	} else {
	    die("*** $0:\n".
		"    LVM physical volume already exists on $fsdevice\n");
	}
    }
}

#
# An existing fstab entry indicates we have already done this
# XXX override with forceit?  Would require unmounting and removing from fstab.
#
if (!system("egrep -q -s '^${fsdevice}' /etc/fstab")) {
    if ($quiet) {
	exit(0);
    } else {
	die("*** $0:\n".
	    "    There is already an entry in /etc/fstab for $fsdevice\n");
    }
}

#
# Likewise, if already mounted somewhere, fail
#
my $mounted = `mount | egrep '^$fsdevice'`;
if ($mounted =~ /^$fsdevice on (\S*)/) {
    if ($quiet) {
	exit(0);
    } else {
	die("*** $0:\n".
	    "    $fsdevice is already mounted on $1\n");
    }
}

#
# Check for valid DOS partition table, since might be secondary disk.
# Used to use "sfdisk -V" but that seems to have quirks.
#
if (system("parted -s $diskdev print >/dev/null 2>&1")) {
    system("parted -s $diskdev mklabel msdos");
    if ($?) {
	die("*** $0:\n".
	    "    Could not write dos label to $diskdev!\n");
    }
    # Grab size (in blocks); DOS cannot handle our huge disks.
    my $disksize = `sfdisk -s $diskdev`;
    if ($?) {
	die("*** $0:\n".
	    "    Could not get size of $diskdev!\n");
    }
    chomp($disksize);
    if ($disksize > (1024 * 1024 * 1024)) {
	$disksize = (1024 * 1024 * 1024);
	print "Disk really big! cutting back to $disksize blocks.\n";
    }
    system("echo '0,$disksize' | sfdisk --force $diskdev -N$slice -u B");
    if ($?) {
	die("*** $0:\n".
	    "    Could not initialize primary partition on $diskdev!\n");
    }
}

my $stype = `sfdisk $diskdev -c $slice`;
if ($stype ne "") {
    chomp($stype);
    $stype = hex($stype);
}
else {
    die("*** $0:\n".
	"    Could not parse slice $slice fdisk entry!\n");
}

#
# Fail if not forcing and the partition type is non-zero.
#
if (!$forceit) {
    if ($stype != 0) {
	die("*** $0:\n".
	    "    non-zero partition type ($stype) for ${disk}${slice}, ".
	    "use -f to override\n");
    }
} elsif ($stype && $stype != 131) {
    warn("*** $0: WARNING: changing partition type from $stype to 131\n");
}

#
# Before we do anything, do lvm if necessary and do not make any filesystems
# inside the vgs unless they want a single monster fs.
#
if ($lvm) {
    my $retval = 0;

    my $blockdevs = "$fsdevice";
    if ($retval = system("pvcreate $blockdevs")) {
	die("*** $0:\n".
	    "    'pvcreate $blockdevs' failed!\n");
    }

    foreach my $vg (@vglist) {
	if (system("vgcreate $vg $blockdevs")) {
	    die("*** $0:\n".
		"    'vgcreate $vg $blockdevs' failed!\n");
	}
    }

    #
    # First, create LVMs whose size is specified.
    #
    my $cnt = -1;
    my $vols_left = scalar(@lvlist);
    foreach my $lv (@lvlist) {
	$cnt = $cnt + 1;
	if ($sizelist[$cnt] != 0) {
	    my $cmd = "lvcreate -n $lv -L ". $sizelist[$cnt]. "M ". $vglist[0];

	    #DEBUG
	    #print("\n$cnt: $cmd");

	    if (system($cmd)) {
		die("*** $0:\n".
		    "    '$cmd' failed!\n");
	    }
		
	    $vols_left = $vols_left - 1;
    	}
    }

    #
    # Now divide up the remaining volume group space among the other LVMs.
    #
    if ($vols_left > 0) {
	$cnt = -1;
	my $vgspace = `vgs --noheadings -o vg_free --units m $vglist[0]`;
	if ($vgspace =~ /\s+([\d\.]+)m/) {
	    # leave some space for rounding to extent boundaries
	    $vgspace = int($1) - (4 * $vols_left);
	} else {
	    $vgspace = 0;
	}
	if ($vgspace == 0) {
	    die("*** $0:\n".
		"    no VG space for remaining volumes!\n");
	}
	$vol_size = int($vgspace / $vols_left);
	foreach my $lv (@lvlist) {
	    $cnt = $cnt + 1;
	    if ($sizelist[$cnt] == 0) {
		my $cmd = "lvcreate -n $lv -L ${vol_size}M ". $vglist[0];

		#DEBUG
		#print("\n$cnt: $cmd");

		if (system($cmd)) {
		    die("*** $0:\n".
			"    '$cmd' failed!\n");
		}
	    }		
	}	
    }

    if ($lmonster) {
	$fsdevice = "/dev/$vglist[0]/$lvlist[0]";
    }
    else {
	exit(0);
    }
}

#
# Set the partition type to Linux if not already set.
#
# XXX sfdisk appears to stomp on partition one's bootblock, at least if it
# is BSD.  It zeros bytes in the block 0x200-0x400, I suspect it is attempting
# to invalidate any BSD disklabel.  While we could just use a scripted fdisk
# sequence here instead, sfdisk is so much more to-the-point.  So, we just
# save off the bootblock, run sfdisk and put the bootblock back.
#
# Would it seek out and destroy other BSD partitions?  Don't know.
# I cannot find the source for sfdisk.
#
if (!$lvm && $stype != 131) {
    die("*** $0:\n".
	"    No $DOSTYPE program, cannot set type of DOS partition\n")
	if (! -e "$DOSTYPE");
    mysystem("$DOSTYPE -f /dev/$disk $slice 131");
}

# eh, quick try for ext3 -- no way we can consistently check the kernel for 
# support, off the top of my head
if ( -e "/sbin/mkfs.ext3") {
    mysystem("mke2fs -j $fsdevice");
    mysystem("echo \"$fsdevice $mountpoint ext3 defaults 0 0\" >> /etc/fstab");
}
else {
    mysystem("mkfs $fsdevice");
    mysystem("echo \"$fsdevice $mountpoint ext2 defaults 0 0\" >> /etc/fstab");
}

mysystem("mount $mountpoint");
mysystem("mkdir $mountpoint/local");

sub mysystem($)
{
    my ($command) = @_;

    if (0) {
	print "'$command'\n";
    }
    else {
	print "'$command'\n";
	system($command);
	if ($?) {
	    die("*** $0:\n".
		"    Failed: '$command'\n");
	}
    }
    return 0;
}
