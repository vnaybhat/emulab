#!/usr/bin/perl -wT
#
# Copyright (c) 2013-2014 University of Utah and the Flux Group.
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

#
# Linux specific routines and constants for the client bootime setup stuff.
#
package liblocstorage;
use Exporter;
@ISA = "Exporter";
@EXPORT =
    qw (
	os_init_storage os_check_storage os_create_storage os_remove_storage
	os_show_storage os_get_diskinfo
       );

sub VERSION()	{ return 1.0; }

# Must come after package declaration!
use English;

# Load up the paths. Its conditionalized to be compatabile with older images.
# Note this file has probably already been loaded by the caller.
BEGIN
{
    if (-e "/etc/emulab/paths.pm") {
	require "/etc/emulab/paths.pm";
	import emulabpaths;
    }
    else {
	my $ETCDIR  = "/etc/rc.d/testbed";
	my $BINDIR  = "/etc/rc.d/testbed";
	my $VARDIR  = "/etc/rc.d/testbed";
	my $BOOTDIR = "/etc/rc.d/testbed";
    }
}

my $MOUNT	= "/bin/mount";
my $UMOUNT	= "/bin/umount";
my $MKDIR	= "/bin/mkdir";
my $MKFS	= "/sbin/mke2fs";
my $FSCK	= "/sbin/e2fsck";
my $DOSTYPE	= "$BINDIR/dostype";
my $ISCSI	= "/sbin/iscsiadm";
my $ISCSI_ALT	= "/usr/bin/iscsiadm";
my $SMARTCTL	= "/usr/sbin/smartctl";
my $BLKID	= "/sbin/blkid";

#
#
# To find the block stores exported from a target portal:
#
#   iscsiadm -m discovery -t sendtargets -p <storage-host>
#
# Display all data for a given node record:
#
#   iscsiadm -m node -T <iqn> -p <storage-host>
#
# Here are the commands to add a remote iSCSI target, set it to be
# mounted at startup, and startup a session (login):
# 
#   iscsiadm -m node -T <iqn> -p <storage-host> -o new
#   iscsiadm -m node -T <iqn> -p <storage-host> -o update \
#              -n node.startup -v automatic
#   iscsiadm -m node -T <iqn> -p <storage-host> -l
# 
# To show active sessions:
# 
#   iscsiadm -m session
# 
# To stop a specific session (logout) and kill its record:
#
#   iscsiadm -m node -T <iqn> -p <storage-host> -u
#   iscsiadm -m node -T <iqn> -p <storage-host> -o delete
#
# To stop all iscsi sessions and kill all records:
# 
#   iscsiadm -m node -U all
#   iscsiadm -m node -o delete
# 
# Once a blockstore is added, you have to use "fdisk -l" or possibly
# crap out in /proc to discover what the name of the disk is.  I've been
# looking for uniform way to query the set of disks on a machine, but
# haven't quite figured this out yet.  The closest thing I've found is
# "fdisk -l".  There are some libraries and such, but there are enough
# of them that I'm not sure which one is best / most standard.
# 

sub iscsi_to_dev($)
{
    my ($session) = @_;

    #
    # XXX this is a total hack and maybe distro dependent?
    #
    my @lines = `ls -l /sys/block/sd? 2>&1`;
    foreach (@lines) {
	if (m#/sys/block/(sd.) -> ../devices/platform/host\d+/session(\d+)#) {
	    if ($2 == $session) {
		return $1;
	    }
	}
    }

    return undef;
}

#
# Returns one if the indicated device is an iSCSI-provided one
# XXX another total hack
#
sub is_iscsi_dev($)
{
    my ($dev) = @_;

    if (-e "/sys/block/$dev") {
	my $line = `ls -l /sys/block/$dev 2>/dev/null`;
	if ($line =~ m#/sys/block/$dev -> ../devices/platform/host\d+/session\d+#) {
	    return 1;
	    }
    }
    return 0;
}

sub find_serial($)
{
    my ($dev) = @_;
    my @lines;

    #
    # Try using "smartctl -i" first
    #
    if (-x "$SMARTCTL") {
	@lines = `$SMARTCTL -i /dev/$dev 2>&1`;
	foreach (@lines) {
	    if (/^serial number:\s+(\S.*)/i) {
		return $1;
	    }
	}
    }

    #
    # Try /dev/disk/by-id.
    # XXX this is a total hack and maybe distro dependent?
    #
    @lines = `ls -l /dev/disk/by-id/ 2>&1`;
    foreach (@lines) {
	if (m#.*_([^_\s]+) -> ../../(sd.)$#) {
	    if ($2 eq $dev) {
		return $1;
	    }
	}
    }

    # XXX Parse dmesg output?

    return undef;
}

#
# Do a one-time initialization of a serial number -> /dev/sd? map.
#
sub init_serial_map()
{
    #
    # XXX this is a total hack and maybe distro dependent?
    #
    my %snmap = ();
    my @lines = `ls -l /sys/block/sd? 2>&1`;
    foreach (@lines) {
	# XXX if a pci device, assume a local disk
	if (m#/sys/block/(sd.) -> ../devices/pci\d+#) {
	    my $dev = $1;
	    $sn = find_serial($dev);
	    if ($sn) {
		$snmap{$sn} = $dev;
	    }
	}
    }

    return \%snmap;
}

sub serial_to_dev($$)
{
    my ($so, $sn) = @_;

    if (defined($so->{'LOCAL_SNMAP'})) {
	my $snmap = $so->{'LOCAL_SNMAP'};
	if (exists($snmap->{$sn})) {
	    return $snmap->{$sn};
	}
    }
    return undef;
}

#
# Return the name (e.g., "sda") of the boot disk, aka the "system volume".
#
sub get_bootdisk()
{
    my $disk = undef;
    my $line = `$MOUNT | grep ' on / '`;

    if ($line && $line =~ /^\/dev\/(\S+)\d+ on \//) {
	$disk = $1;
    }
    return $disk;
}

sub get_parttype($$)
{
    my ($dev,$pnum) = @_;

    my $ptype = `sfdisk /dev/$dev -c $pnum`;
    if ($ptype) {
	chomp($ptype);
	if ($ptype =~ /^([\da-fA-F]+)$/) {
	    $ptype = hex($1);
	} else {
	    $ptype = -1;
	}
    } else {
	$ptype = -1;
    }

    return $ptype;
}

#
# Returns 1 if the volume manager has been initialized.
# For LVM this means that the "emulab" volume group exists.
#
sub is_lvm_initialized()
{
    my $vg = `vgs -o vg_name --noheadings emulab 2>/dev/null`;
    if ($vg) {
	return 1;
    }
    return 0;
}

#
# Get information about local disks.
#
# Ideally, this comes from the list of ELEMENTs passed in.
#
# But if that is not available, we figure it out outselves by using
# a simplified version of the libvnode findSpareDisks.
# XXX the various "get space on the local disk" mechanisms should be
# reconciled.
#
sub get_diskinfo()
{
    my %geominfo = ();

    #
    # Get the list of partitions.
    # XXX only care about sd[a-z] devices and their partitions.
    #
    if (!open(FD, "/proc/partitions")) {
	warn("*** get_diskinfo: could not get disk info from /proc/partitions\n");
	return undef;
    }
    while (<FD>) {
	if (/^\s+\d+\s+\d+\s+(\d+)\s+(sd[a-z])(\d+)?/) {
	    my ($size,$dev,$part) = ($1,$2,$3);
	    # DOS partition
	    if (defined($part)) {
		# XXX avoid garbage and extended partitions
		next if ($part < 1 || $part > 4);

		my $pdev = "$dev$part";
		$geominfo{$pdev}{'level'} = 1;
		$geominfo{$pdev}{'type'} = "PART";
		$geominfo{$pdev}{'size'} = int($size / 1024);
		$geominfo{$pdev}{'inuse'} = get_parttype($dev, $part);
	    }
	    # XXX iSCSI disk
	    elsif (is_iscsi_dev($dev)) {
		$geominfo{$dev}{'level'} = 0;
		$geominfo{$dev}{'type'} = "iSCSI";
		$geominfo{$dev}{'size'} = int($size / 1024);
		$geominfo{$dev}{'inuse'} = -1;
	    }
	    # raw local disk
	    else {
		$geominfo{$dev}{'level'} = 0;
		$geominfo{$dev}{'type'} = "DISK";
		$geominfo{$dev}{'size'} = int($size / 1024);
		$geominfo{$dev}{'inuse'} = 0;
	    }
	}
    }
    close(FD);

    # XXX watch out for mounted disks/partitions (DOS type may be 0)
    if (!open(FD, "/etc/fstab")) {
	warn("*** get_diskinfo: could not get mount info from /etc/fstab\n");
	return undef;
    }
    while (<FD>) {
	if (/^\/dev\/(sd\S+)/) {
	    my $dev = $1;
	    if (exists($geominfo{$dev}) && $geominfo{$dev}{'inuse'} == 0) {
		$geominfo{$dev}{'inuse'} = -1;
	    }
	}
    }
    close(FD);

    #
    # Make a pass through and mark disks that are in use where "in use"
    # means "has a partition".
    #
    foreach my $dev (keys %geominfo) {
	if ($geominfo{$dev}{'type'} eq "PART" &&
	    $geominfo{$dev}{'level'} == 1 &&
	    $dev =~ /^(.*)\d+$/) {
	    if (exists($geominfo{$1}) && $geominfo{$1}{'inuse'} == 0) {
		$geominfo{$1}{'inuse'} = 1;
	    }
	}
    }

    #
    # Find disks/partitions in use by LVM and update the available size
    #
    if (open(FD, "pvs -o pv_name,pv_size --units m --noheadings|")) {
	while (<FD>) {
	    if (/^\s+\/dev\/(\S+)\s+(\d+)\.\d+m$/) {
		my $dev = $1;
		my $size = $2;
		$geominfo{$dev}{'size'} = $size;
		$geominfo{$dev}{'inuse'} = -1;
	    }
	}
	close(FD);
    }
    #
    # See if there are any volume groups.
    # We don't care about the specific output
    #
    my $gotvgs = 0;
    my $vgs = `vgs -o vg_name --noheadings 2>/dev/null`;
    if ($vgs) {
	$gotvgs = 1;
    }

    #
    # Record any LVs as well.
    # We only do this if we know there are volume groups, else lvs will fail.
    #
    if ($gotvgs &&
	open(FD, "lvs -o vg_name,lv_name,lv_size --units m --noheadings|")) {
	while (<FD>) {
	    if (/^\s+(\S+)\s+(\S+)\s+(\d+)\.\d+m$/) {
		my $vg = $1;
		my $lv = $2;
		my $size = $3;
		my $dev = "$vg/$lv";

		$geominfo{$dev}{'level'} = 2;
		$geominfo{$dev}{'type'} = "LVM";
		$geominfo{$dev}{'size'} = $size;
		$geominfo{$dev}{'inuse'} = 1;
	    }
	}
	close(FD);
    }

    return \%geominfo;
}

#
# See if this is a filesystem type we can deal with.
# If so, return the type suitable for use by fsck and mount.
#
sub get_fstype($$;$)
{
    my ($href,$dev,$rwref) = @_;
    my $type = "";

    #
    # If there is an explicit type set, believe it.
    #
    if (exists($href->{'FSTYPE'})) {
	$type = $href->{'FSTYPE'};
    }

    #
    # No explicit type set, see if we can intuit what the FS is.
    #
    else {
	my $blkid = `$BLKID -s TYPE -o value $dev`;
	if ($? == 0) {
	    chomp($blkid);
	    $type = $blkid;
	}

	if ($type && !exists($href->{'FSTYPE'})) {
	    $href->{'FSTYPE'} = $type;
	}
    }

    # ext? is okay
    if ($type =~ /^ext[234]$/) {
	if ($rwref) {
	    $$rwref = 1;
	}
	return $type;
    }

    # UFS can be mounted RO
    if ($type eq "ufs") {
	if ($rwref) {
	    $$rwref = 0;
	}
	return "ufs";
    }

    if ($rwref) {
	$$rwref = 0;
    }
    return undef;
}

#
# Handle one-time operations.
# Return a cookie (object) with current state of storage subsystem.
#
sub os_init_storage($)
{
    my ($lref) = @_;
    my $redir = ">/dev/null 2>&1";

    my $gotlocal = 0;
    my $gotnonlocal = 0;
    my $gotelement = 0;
    my $gotslice = 0;
    my $gotiscsi = 0;
    my $needavol = 0;
    my $needall = 0;

    my %so = ();

    foreach my $href (@{$lref}) {
	if ($href->{'CMD'} eq "ELEMENT") {
	    $gotelement++;
	} elsif ($href->{'CMD'} eq "SLICE") {
	    $gotslice++;
	    if ($href->{'BSID'} eq "SYSVOL" ||
		$href->{'BSID'} eq "ONSYSVOL") {
		$needavol = 1;
	    } elsif ($href->{'BSID'} eq "ANY") {
		$needall = 1;
	    }
	}
	if ($href->{'CLASS'} eq "local") {
	    $gotlocal++;
	} else {
	    $gotnonlocal++;
	    if ($href->{'PROTO'} eq "iSCSI") {
		$gotiscsi++;
	    }
	}
    }

    # check for local storage incompatibility
    if ($needall && $needavol) {
	warn("*** storage: Incompatible local volumes.\n");
	return undef;
    }
	
    # initialize mapping of serial numbers to devices
    if ($gotlocal && $gotelement) {
	$so{'LOCAL_SNMAP'} = init_serial_map();
    }

    # initialize volume manage if needed for local slices
    if ($gotlocal && $gotslice) {
	#
	# Allow for the volume group to exist.
	#
	if (is_lvm_initialized()) {
	    $so{'LVM_VGCREATED'} = 1;
	}

	#
	# Grab the bootdisk and current GEOM state
	#
	my $bdisk = get_bootdisk();
	my $ginfo = get_diskinfo();
	if (!exists($ginfo->{$bdisk}) || $ginfo->{$bdisk}->{'inuse'} == 0) {
	    warn("*** storage: bootdisk '$bdisk' marked as not in use!?\n");
	    return undef;
	}
	$so{'BOOTDISK'} = $bdisk;
	$so{'DISKINFO'} = $ginfo;
    }

    if ($gotiscsi) {
	if (! -x "$ISCSI") {
	    if (! -x "$ISCSI_ALT") {
		warn("*** storage: $ISCSI does not exist, cannot continue\n");
		return undef;
	    }
	    $ISCSI = $ISCSI_ALT;
	}
	#
	# XXX don't grok the Ubuntu startup, so...
	# make sure automatic sessions are started
	#
	my $nsess = `$ISCSI -m session 2>/dev/null | grep -c ^`;
	chomp($nsess);
	if ($nsess == 0) {
	    mysystem("$ISCSI -m node --loginall=automatic $redir");
	}
    }

    $so{'INITIALIZED'} = 1;
    return \%so;
}

sub os_get_diskinfo($)
{
    my ($so) = @_;

    return get_diskinfo();
}

#
# XXX debug
#
sub os_show_storage($)
{
    my ($so) = @_;

    my $bdisk = $so->{'BOOTDISK'};
    print STDERR "OS Dep info:\n";
    print STDERR "  BOOTDISK=$bdisk\n" if ($bdisk);

    my $dinfo = get_diskinfo();
    if ($dinfo) {
	print STDERR "  DISKINFO:\n";
	foreach my $dev (keys %$dinfo) {
	    my $type = $dinfo->{$dev}->{'type'};
	    my $lev = $dinfo->{$dev}->{'level'};
	    my $size = $dinfo->{$dev}->{'size'};
	    my $inuse = $dinfo->{$dev}->{'inuse'};
	    print STDERR "    name=$dev, type=$type, level=$lev, size=$size, inuse=$inuse\n";
	}
    }

    # LOCAL_SNMAP
    my $snmap = $so->{'LOCAL_SNMAP'};
    if ($so->{'LOCAL_SNMAP'}) {
	my $snmap = $so->{'LOCAL_SNMAP'};

	print STDERR "  LOCAL_SNMAP:\n";
	foreach my $sn (keys %$snmap) {
	    print STDERR "    $sn -> ", $snmap->{$sn}, "\n";
	}
    }
}

#
# os_check_storage(sobject,confighash)
#
#   Determines if the storage unit described by confighash exists and
#   is properly configured. Returns zero if it doesn't exist, 1 if it
#   exists and is correct, -1 otherwise.
#
#   Side-effect: Creates the hash member $href->{'LVDEV'} with the /dev
#   name of the storage unit.
#
sub os_check_storage($$)
{
    my ($so,$href) = @_;

    if ($href->{'CMD'} eq "ELEMENT") {
	return os_check_storage_element($so,$href);
    }
    if ($href->{'CMD'} eq "SLICE") {
	return os_check_storage_slice($so,$href);
    }
    return -1;
}

sub os_check_storage_element($$)
{
    my ($so,$href) = @_;
    my $CANDISCOVER = 0;
    my $redir = ">/dev/null 2>&1";

    #
    # iSCSI:
    #  make sure the IQN exists
    #  make sure a session exists
    #
    if ($href->{'CLASS'} eq "SAN" && $href->{'PROTO'} eq "iSCSI") {
	my $hostip = $href->{'HOSTIP'};
	my $uuid = $href->{'UUID'};
	my $bsid = $href->{'VOLNAME'};
	my @lines;

	#
	# See if the block store exists on the indicated server.
	# If not, something is very wrong, return -1.
	#
	# Note that the server may not support discovery. If not, we don't
	# do it since it is only a sanity check anyway.
	#
	if ($CANDISCOVER) {
	    @lines = `$ISCSI -m discovery -t sendtargets -p $hostip 2>&1`;
	    if ($? != 0) {
		warn("*** could not find exported iSCSI block stores\n");
		return -1;
	    }
	    if (!grep(/$uuid/, @lines)) {
		warn("*** could not find iSCSI block store '$uuid'\n");
		return -1;
	    }
	}

	#
	# It exists, are we connected to it?
	# If not, we have not done the one-time initialization, return 0.
	#
	my $session;
	@lines = `$ISCSI -m session 2>&1`;
	foreach (@lines) {
	    if (/^tcp: \[(\d+)\].*$uuid */) {
		$session = $1;
		last;
	    }
	}
	if (!defined($session)) {
	    return 0;
	}

	#
	# If there is no session, we have a problem.
	#
	my $dev = iscsi_to_dev($session);
	if (!defined($dev)) {
	    warn("*** $bsid: found iSCSI session but could not determine local device\n");
	    return -1;
	}
	$href->{'LVDEV'} = "/dev/$dev";

	#
	# If there is a mount point, see if it is mounted.
	#
	# XXX because mounts in /etc/fstab happen before iSCSI and possibly
	# even the network are setup, we don't put our mounts there as we
	# do for local blockstores. Thus, if the blockstore device is not
	# mounted, we do it here.
	#
	my $mpoint = $href->{'MOUNTPOINT'};
	if ($mpoint) {
	    my $line = `$MOUNT | grep '^/dev/$dev on '`;
	    if (!$line) {
		my $mopt = "";
		my $fopt = "-p";

		# determine the filesystem type
		my $rw = 0;
		my $fstype = get_fstype($href, "/dev/$dev", \$rw);
		if (!$fstype) {
		    if (exists($href->{'FSTYPE'})) {
			warn("*** $bsid: unsupported FS (".
			     $href->{'FSTYPE'}.
			     ") on /dev/$dev\n");
		    } else {
			warn("*** $bsid: unknown FS on /dev/$dev\n");
		    }
		    return -1;
		}

		# check for RO export and adjust options accordingly
		if ($href->{'PERMS'} eq "RO") {
		    $mopt = "-o ro";
		    # XXX for ufs
		    if ($fstype eq "ufs") {
			$mopt .= ",ufstype=ufs2";
		    }
		    $fopt = "-n";
		}
		# OS only supports RO mounting, right now we just fail
		elsif ($rw == 0) {
		    warn("*** $bsid: OS only supports RO mounting of ".
			 $href->{'FSTYPE'}. " FSes\n");
		    return -1;
		}

		# the mountpoint should exist
		if (! -d "$mpoint") {
		    warn("*** $bsid: no mount point $mpoint\n");
		    return -1;
		}

		# fsck it in case of an abrupt shutdown
		# XXX cannot fsck ufs
		if ($fstype ne "ufs" &&
		    mysystem("$FSCK $fopt /dev/$dev $redir")) {
		    warn("*** $bsid: fsck of /dev/$dev failed\n");
		    return -1;
		}
		if (mysystem("$MOUNT $mopt /dev/$dev $mpoint $redir")) {
		    warn("*** $bsid: could not mount /dev/$dev on $mpoint\n");
		    return -1;
		}
	    }
	    elsif ($line !~ /^\/dev\/$dev on (\S+) / || $1 ne $mpoint) {
		warn("*** $bsid: mounted on $1, should be on $mpoint\n");
		return -1;
	    }
	}

	return 1;
    }

    #
    # local disk:
    #  make sure disk exists
    #
    if ($href->{'CLASS'} eq "local") {
	my $bsid = $href->{'VOLNAME'};
	my $sn = $href->{'UUID'};

	my $dev = serial_to_dev($so, $sn);
	if (defined($dev)) {
	    $href->{'LVDEV'} = "/dev/$dev";
	    return 1;
	}

	# XXX not an error for now, until we can be sure that we can
	# get SN info for all disks
	$href->{'LVDEV'} = "<UNKNOWN>";
	return 1;

	# for physical disks, there is no way to "create" it so return error
	warn("*** $bsid: could not find HD with serial '$sn'\n");
	return -1;
    }

    warn("*** $bsid: unsupported class/proto '" .
	 $href->{'CLASS'} . "/" . $href->{'PROTO'} . "'\n");
    return -1;
}

#
# Return 0 if does not exist
# Return 1 if exists and correct
# Return -1 otherwise
#
sub os_check_storage_slice($$)
{
    my ($so,$href) = @_;
    my $bsid = $href->{'BSID'};

    #
    # local storage:
    #  if BSID==SYSVOL:
    #    see if 4th part of boot disk exists (eg: da0s4) and
    #    is of type freebsd
    #  else if BSID==NONSYSVOL:
    #    see if there is a concat volume with appropriate name
    #  else if BSID==ANY:
    #    see if there is a concat volume with appropriate name
    #  if there is a mountpoint, see if it exists in /etc/fstab
    #
    # List all volumes:
    #   gvinum lv
    #
    #
    if ($href->{'CLASS'} eq "local") {
	my $lv = $href->{'VOLNAME'};
	my ($dev, $devtype, $mdev);

	my $ginfo = $so->{'DISKINFO'};
	my $bdisk = $so->{'BOOTDISK'};

	# figure out the device of interest
	if ($bsid eq "SYSVOL") {
	    $dev = $mdev = "${bdisk}4";
	    $devtype = "PART";
	} else {
	    $dev = "emulab/$lv";
	    $mdev = "mapper/emulab-$lv";
	    $devtype = "LVM";
	}
	my $devsize = $href->{'VOLSIZE'};

	# if the device does not exist, return 0
	if (!exists($ginfo->{$dev})) {
	    return 0;
	}
	# if it exists but is of the wrong type, we have a problem!
	my $atype = $ginfo->{$dev}->{'type'};
	if ($atype ne $devtype) {
	    warn("*** $lv: actual type ($atype) != expected type ($devtype)\n");
	    return -1;
	}
	#
	# Ditto for size, unless this is the SYSVOL where we ignore user size
	# or if the size was not specified.
	#
	# XXX Note that the size of the volume may be rounded up from what we
	# asked for, hopefully not more than 1 MiB!
	#
	my $asize = $ginfo->{$dev}->{'size'};
	if ($bsid ne "SYSVOL" && $devsize &&
	    !($asize == $devsize || $asize == $devsize+1)) {
	    warn("*** $lv: actual size ($asize) != expected size ($devsize)\n");
	    return -1;
	}

	# for the system disk, ensure partition is not in use
	if ($bsid eq "SYSVOL") {
	    # XXX inuse for a partition is set to DOS type
	    my $ptype = $ginfo->{$dev}->{'inuse'};

	    # if type is 0, it is not setup
	    if ($ptype == 0) {
		return 0;
	    }
	    # ow, if type is not 131, there is a problem
	    if ($ptype != 131) {
		warn("*** $lv: $dev already in use (type $ptype)\n");
		return -1;
	    }
	}

	# if there is a mountpoint, make sure it is mounted
	my $mpoint = $href->{'MOUNTPOINT'};
	if ($mpoint) {
	    my $line = `$MOUNT | grep '^/dev/$mdev on '`;
	    if (!$line && mysystem("$MOUNT $mpoint")) {
		warn("*** $lv: is not mounted, should be on $mpoint\n");
		return -1;
	    }
	    if ($line && ($line !~ /^\/dev\/$mdev on (\S+) / || $1 ne $mpoint)) {
		warn("*** $lv: mounted on $1, should be on $mpoint\n");
		return -1;
	    }
	}

	$href->{'LVDEV'} = "/dev/$dev";
	return 1;
    }

    warn("*** $bsid: unsupported class '" . $href->{'CLASS'} . "'\n");
    return -1;
}

#
# os_create_storage(confighash)
#
#   Create the storage unit described by confighash. Unit must not exist
#   (os_check_storage should be called first to verify). Return one on
#   success, zero otherwise.
#
sub os_create_storage($$)
{
    my ($so,$href) = @_;
    my $fstype;
    my $rv = 0;

    # record all the output for debugging
    my $log = "/var/emulab/logs/" . $href->{'VOLNAME'} . ".out";
    mysystem("cp /dev/null $log");

    if ($href->{'CMD'} eq "ELEMENT") {
	$rv = os_create_storage_element($so, $href, $log);
    }
    elsif ($href->{'CMD'} eq "SLICE") {
	$rv = os_create_storage_slice($so, $href, $log);
    }
    if ($rv == 0) {
	return 0;
    }

    my $mopt = "";
    my $fopt = "-p";

    if (exists($href->{'MOUNTPOINT'})) {
	my $lv = $href->{'VOLNAME'};
	my $mdev = $href->{'LVDEV'};

	# record all the output for debugging
	my $redir = "";
	my $logmsg = "";
	if ($log) {
	    $redir = ">>$log 2>&1";
	    $logmsg = ", see $log";
	}

	#
	# If this is a persistent iSCSI disk, we never create the filesystem!
	# Instead, we fsck it in case it was not shutdown cleanly in its
	# previous existence.
	#
	if ($href->{'CLASS'} eq "SAN" && $href->{'PROTO'} eq "iSCSI" &&
	    $href->{'PERSIST'} != 0) {
	    # determine the filesystem type
	    my $rw = 0;
	    $fstype = get_fstype($href, $mdev, \$rw);
	    if (!$fstype) {
		if (exists($href->{'FSTYPE'})) {
		    warn("*** $lv: unsupported FS (".
			 $href->{'FSTYPE'}.
			 ") on $mdev\n");
		} else {
		    warn("*** $lv: unknown FS on $mdev\n");
		}
		return 0;
	    }

	    # check for RO export and adjust options accordingly
	    if ($href->{'PERMS'} eq "RO") {
		$mopt = "-o ro";
		# XXX for ufs
		if ($fstype eq "ufs") {
		    $mopt .= ",ufstype=ufs2";
		}
		$fopt = "-n";
	    }
	    # OS only supports RO mounting, right now we just fail
	    elsif ($rw == 0) {
		warn("*** $lv: OS only supports RO mounting of ".
		     $href->{'FSTYPE'}. " FSes\n");
		return 0;
	    }

	    # XXX cannot fsck ufs
	    if ($fstype ne "ufs" &&
		mysystem("$FSCK $fopt $mdev $redir")) {
		warn("*** $lv: fsck of persistent store $mdev failed\n");
		return 0;
	    }

	}
	#
	# Otherwise, create the filesystem:
	#
	# Start by trying ext4 which is much faster when creating large FSes.
	# Otherwise fall back on ext3 and then ext2.
	#
	else {
	    my $failed = 1;
	    my $fsopts = "-F -q";
	    if ($failed) {
		$fstype = "ext4";
		$fsopts .= " -E lazy_itable_init=1";
		$failed = mysystem("$MKFS -t $fstype $fsopts $mdev $redir");
	    }
	    if ($failed) {
		$fstype = "ext3";
		$failed = mysystem("$MKFS -t $fstype $fsopts $mdev $redir");
	    }
	    if ($failed) {
		$fstype = "ext2";
		$failed = mysystem("$MKFS -t $fstype $fsopts $mdev $redir");
	    }
	    if ($failed) {
		warn("*** $lv: could not create FS\n");
		return 0;
	    }
	}

	#
	# Mount the filesystem
	#
	my $mpoint = $href->{'MOUNTPOINT'};
	if (! -d "$mpoint" && mysystem("$MKDIR -p $mpoint $redir")) {
	    warn("*** $lv: could not create mountpoint '$mpoint'$logmsg\n");
	    return 0;
	}

	#
	# XXX because mounts in /etc/fstab happen before iSCSI and possibly
	# even the network are setup, we don't put our mounts there as we
	# do for local blockstores. Instead, the check_storage call will
	# take care of these mounts.
	#
	if (!($href->{'CLASS'} eq "SAN" && $href->{'PROTO'} eq "iSCSI")) {
	    if (!open(FD, ">>/etc/fstab")) {
		warn("*** $lv: could not add mount to /etc/fstab\n");
		return 0;
	    }
	    print FD "# $mdev added by $BINDIR/rc/rc.storage\n";
	    print FD "$mdev\t$mpoint\t$fstype\tdefaults\t0\t0\n";
	    close(FD);
	    if (mysystem("$MOUNT $mpoint $redir")) {
		warn("*** $lv: could not mount on $mpoint$logmsg\n");
		return 0;
	    }
	} else {
	    if (mysystem("$MOUNT $mopt -t $fstype $mdev $mpoint $redir")) {
		warn("*** $lv: could not mount $mdev on $mpoint$logmsg\n");
		return 0;
	    }
	}
    }

    return 1;
}

sub os_create_storage_element($$$)
{
    my ($so,$href,$log) = @_;

    if ($href->{'CLASS'} eq "SAN" && $href->{'PROTO'} eq "iSCSI") {
	my $hostip = $href->{'HOSTIP'};
	my $uuid = $href->{'UUID'};
	my $bsid = $href->{'VOLNAME'};

	# record all the output for debugging
	my $redir = "";
	my $logmsg = "";
	if ($log) {
	    $redir = ">>$log 2>&1";
	    $logmsg = ", see $log";
	}

	#
	# Perform one time iSCSI operations
	#
	if (mysystem("$ISCSI -m node -T $uuid -p $hostip -o new $redir") ||
	    mysystem("$ISCSI -m node -T $uuid -p $hostip -o update -n node.startup -v automatic $redir") ||
	    mysystem("$ISCSI -m node -T $uuid -p $hostip -l $redir")) {
	    warn("*** Could not perform first-time initialization of block store $bsid (uuid=$uuid)$logmsg\n");
	    return 0;
	}

	#
	# Make sure we are connected
	#
	@lines = `$ISCSI -m session 2>&1`;
	foreach (@lines) {
	    if (/^tcp: \[(\d+)\].*$uuid */) {
		$session = $1;
		last;
	    }
	}
	if (!defined($session)) {
	    warn("*** Could not locate session for block store $bsid (uuid=$uuid)\n");
	    return 0;
	}

	#
	# Map to a local device.
	#
	my $dev = iscsi_to_dev($session);
	if (!defined($dev)) {
	    #
	    # XXX apparently the device may not show up immediately,
	    # so pause and try again.
	    #
	    sleep(1);
	    $dev = iscsi_to_dev($session);
	    if (!defined($dev)) {
		warn("*** $bsid: could not map iSCSI session to device\n");
		return 0;
	    }
	}

	$href->{'LVDEV'} = "/dev/$dev";
	return 1;
    }

    warn("*** Only support iSCSI now\n");
    return 0;
}

sub os_create_storage_slice($$$)
{
    my ($so,$href,$log) = @_;
    my $bsid = $href->{'BSID'};

    #
    # local storage:
    #  if BSID==SYSVOL:
    #     create the 4th part of boot disk with type Linux,
    #	  create a native filesystem (that imagezip would understand).
    #  else if BSID==NONSYSVOL:
    #	  create an LVM PV/VG from all available extra hard drives
    #	  (one-time), create LV with appropriate name from VG.
    #  else if BSID==ANY:
    #	  create an LVM PV/VG from all available space (part 4 on sysvol,
    #	  extra hard drives), create LV with appropriate name from VG.
    #  if there is a mountpoint:
    #     create a filesystem on device, mount it, add to /etc/fstab
    #
    if ($href->{'CLASS'} eq "local") {
	my $lv = $href->{'VOLNAME'};
	my $lvsize = $href->{'VOLSIZE'};
	my $mdev = "";

	my $bdisk = $so->{'BOOTDISK'};
	my $ginfo = $so->{'DISKINFO'};

	# record all the output for debugging
	my $redir = "";
	my $logmsg = "";
	if ($log) {
	    $redir = ">>$log 2>&1";
	    $logmsg = ", see $log";
	}

	#
	# System volume:
	#
	# dostype -f /dev/sda 4 131
	#
	if ($bsid eq "SYSVOL") {
	    if (mysystem("$DOSTYPE -f /dev/$bdisk 4 131")) {
		warn("*** $lv: could not set /dev/$bdisk type$logmsg\n");
		return 0;
	    }
	    $mdev = "$bdisk" . "4";
	}
	#
	# Non-system volume or all space.
	#
	else {
	    #
	    # If LVM has not yet been initialized handle that:
	    #
	    if (!exists($so->{'LVM_VGCREATED'})) {
		my @devs = ();
		my $dev;

		if ($bsid eq "ANY") {
		    $dev = $bdisk . "4";
		    if ($ginfo->{$dev}->{'inuse'} == 0) {
			push(@devs, "/dev/$dev");
		    }
		}
		foreach $dev (keys %$ginfo) {
		    if ($ginfo->{$dev}->{'type'} eq "DISK" &&
			$ginfo->{$dev}->{'inuse'} == 0) {
			push(@devs, "/dev/$dev");
		    }
		}
		if (@devs == 0) {
		    warn("*** $lv: no space found\n");
		    return 0;
		}

		#
		# Create the volume group:
		#
		# pvcreate /dev/sdb /dev/sda4		(ANY)
		# vgcreate emulab /dev/sdb /dev/sda4	(ANY)
		#
		# pvcreate /dev/sdb			(NONSYSVOL)
		# vgcreate emulab /dev/sdb		(NONSYSVOL)
		#
		if (mysystem("pvcreate @devs $redir")) {
		    warn("*** $lv: could not create PVs '@devs'$logmsg\n");
		    return 0;
		}
		if (mysystem("vgcreate emulab @devs $redir")) {
		    warn("*** $lv: could not create VG from '@devs'$logmsg\n");
		    return 0;
		}

		$so->{'LVM_VGCREATED'} = 1;
	    }

	    #
	    # Now create an LV for the volume:
	    #
	    # lvcreate -n h2d2 -L 100m emulab
	    #
	    if ($lvsize == 0) {
		my $sz = `vgs -o vg_size --units m --noheadings emulab`;
		if ($sz =~ /([\d\.]+)/) {
		    $lvsize = int($1);
		} else {
		    warn("*** $lv: could not find size of VG\n");
		}
	    }
	    if (mysystem("lvcreate -n $lv -L ${lvsize}m emulab $redir")) {
		warn("*** $lv: could not create LV$logmsg\n");
		return 0;
	    }

	    $mdev = "emulab/$lv";
	}

	$href->{'LVDEV'} = "/dev/$mdev";
	return 1;
    }

    warn("*** $bsid: unsupported class '" . $href->{'CLASS'} . "'\n");
    return 0;
}

sub os_remove_storage($$$)
{
    my ($so,$href,$teardown) = @_;

    if ($href->{'CMD'} eq "ELEMENT") {
	return os_remove_storage_element($so, $href, $teardown);
    }
    if ($href->{'CMD'} eq "SLICE") {
	return os_remove_storage_slice($so, $href, $teardown);
    }
    return 0;
}

sub os_remove_storage_element($$$)
{
    my ($so,$href,$teardown) = @_;
    #my $redir = "";
    my $redir = ">/dev/null 2>&1";

    if ($href->{'CLASS'} eq "SAN" && $href->{'PROTO'} eq "iSCSI") {
	my $hostip = $href->{'HOSTIP'};
	my $uuid = $href->{'UUID'};
	my $bsid = $href->{'VOLNAME'};

	#
	# Unmount it
	#
	if (exists($href->{'MOUNTPOINT'})) {
	    my $mpoint = $href->{'MOUNTPOINT'};

	    if (mysystem("$UMOUNT $mpoint")) {
		warn("*** $bsid: could not unmount $mpoint\n");
	    }
	}

	#
	# Logout of the session.
	# XXX continue even if we could not logout.
	#
	if (mysystem("$ISCSI -m node -T $uuid -p $hostip -u $redir")) {
	    warn("*** $bsid: Could not logout iSCSI sesssion (uuid=$uuid)\n");
	}

	if ($teardown &&
	    mysystem("$ISCSI -m node -T $uuid -p $hostip -o delete $redir")) {
	    warn("*** $bsid: could not perform teardown of iSCSI block store (uuid=$uuid)\n");
	    return 0;
	}

	return 1;
    }

    #
    # Nothing to do (yet) for a local disk
    #
    if ($href->{'CLASS'} eq "local") {
	return 1;
    }

    warn("*** Only support iSCSI now\n");
    return 0;
}

#
# teardown==0 means we are rebooting: unmount and shutdown gvinum
# teardown==1 means we are reconfiguring and will be destroying everything
#
sub os_remove_storage_slice($$$)
{
    my ($so,$href,$teardown) = @_;

    if ($href->{'CLASS'} eq "local") {
	my $bsid = $href->{'BSID'};
	my $lv = $href->{'VOLNAME'};

	my $ginfo = $so->{'DISKINFO'};
	my $bdisk = $so->{'BOOTDISK'};

	# figure out the device of interest
	my ($dev, $devtype, $mdev);
	if ($bsid eq "SYSVOL") {
	    $dev = $mdev = "${bdisk}4";
	    $devtype = "PART";
	} else {
	    $dev = "emulab/$lv";
	    $mdev = "mapper/emulab-$lv";
	    $devtype = "LVM";
	}

	# if the device does not exist, we have a problem!
	if (!exists($ginfo->{$dev})) {
	    warn("*** $lv: device '$dev' does not exist\n");
	    return 0;
	}
	# ditto if it exists but is of the wrong type
	my $atype = $ginfo->{$dev}->{'type'};
	if ($atype ne $devtype) {
	    warn("*** $lv: actual type ($atype) != expected type ($devtype)\n");
	    return 0;
	}

	# record all the output for debugging
	my $log = "/var/emulab/logs/$lv.out";
	my $redir = ">>$log 2>&1";
	my $logmsg = ", see $log";
	mysystem("cp /dev/null $log");

	#
	# Unmount and remove mount info from fstab.
	#
	# On errors, we warn but don't stop. We do everything in our
	# power to take things down.
	#
	if (exists($href->{'MOUNTPOINT'})) {
	    my $mpoint = $href->{'MOUNTPOINT'};

	    if (mysystem("$UMOUNT $mpoint")) {
		warn("*** $lv: could not unmount $mpoint\n");
	    }

	    if ($teardown) {
		my $tdev = "/dev/$dev";
		$tdev =~ s/\//\\\//g;
		if (mysystem("sed -E -i -e '/^(# )?$tdev/d' /etc/fstab")) {
		    warn("*** $lv: could not remove mount from /etc/fstab\n");
		}
	    }
	}

	#
	# Remove LV
	#
	if ($teardown) {
	    #
	    # System volume:
	    #
	    # dostype -f /dev/sda 4 0
	    #
	    if ($bsid eq "SYSVOL") {
		if (mysystem("$DOSTYPE -f /dev/$bdisk 4 0")) {
		    warn("*** $lv: could not clear /dev/$bdisk type$logmsg\n");
		    return 0;
		}
		return 1;
	    }

	    #
	    # Other, LVM volume:
	    #
	    # lvremove -f emulab/h2d2
	    #
	    if (mysystem("lvremove -f emulab/$lv $redir")) {
		warn("*** $lv: could not destroy$logmsg\n");
	    }

	    #
	    # If no volumes left:
	    #
	    # Remove the VG:
	    #  vgremove -f emulab
	    # Remove the PVs:
	    #  pvremove -f /dev/sda4 /dev/sdb
	    #
	    my $gotlvs = 0;
	    my $lvs = `lvs -o vg_name --noheadings emulab 2>/dev/null`;
	    if ($lvs) {
		return 1;
	    }

	    if (mysystem("vgremove -f emulab $redir")) {
		warn("*** $lv: could not destroy VG$logmsg\n");
	    }

	    my @devs = `pvs -o pv_name --noheadings 2>/dev/null`;
	    chomp(@devs);
	    if (@devs > 0 && mysystem("pvremove -f @devs $redir")) {
		warn("*** $lv: could not destroy PVs$logmsg\n");
	    }
	}

	return 1;
    }

    return 0;
}

sub mysystem($)
{
    my ($cmd) = @_;
    if (0) {
	print STDERR "CMD: $cmd\n";
    }
    return system($cmd);
}

sub mybacktick($)
{
    my ($cmd) = @_;
    if (0) {
	print STDERR "CMD: $cmd\n";
    }
    return `$cmd`;
}

1;
