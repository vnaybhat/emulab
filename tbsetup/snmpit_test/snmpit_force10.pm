#!/usr/bin/perl -w

#
# Copyright (c) 2013,2014 University of Utah and the Flux Group.
# Copyright (c) 2006-2014 Universiteit Gent/iMinds, Belgium.
# Copyright (c) 2004-2006 Regents, University of California.
# 
# {{{EMULAB-LGPL
# 
# This file is part of the Emulab network testbed software.
# 
# This file is free software; you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation; either version 2.1 of the License, or (at
# your option) any later version.
# 
# This file is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
# License for more details.
# 
# You should have received a copy of the GNU Lesser General Public License
# along with this file.  If not, see <http://www.gnu.org/licenses/>.
# 
# }}}
#

#
# snmpit module for Force10 switches
#

package snmpit_force10;
use strict;
use Data::Dumper;

$| = 1; # Turn off line buffering on output

use English;
use SNMP;
use snmpit_lib;
use Port;
use force10_expect;

#
# These are the commands that can be passed to the portControl function
# below
#
my %cmdOIDs =
(
	"enable"  => ["ifAdminStatus","up"],
	"disable" => ["ifAdminStatus","down"],
);

#
# Force10 Chassis configuration info
#
my $ChassisInfo = {
    "force10c300" => {
        "moduleSlots"           => 8,   # Max # of modules in chassis
        "maxPortsPerModule"     => 48,  # Max # of ports in any module
        "bitmaskBitsPerModule"  => 224, # Number of bits per module
    },
    "force10e1200" => {
        "moduleSlots"           => 14,  # Max # of modules in chassis
        "maxPortsPerModule"     => 48,  # Max # of ports in any module
        "bitmaskBitsPerModule"  => 96,  # Number of bits per module
    },
    "force10s55" => {
        "moduleSlots"           => 1,   # Max # of modules in chassis
        "maxPortsPerModule"     => 64,  # Max # of ports in any module
        "bitmaskBitsPerModule"  => 768, # Number of bits per module
    },
    "force10-z9000" => {
        "moduleSlots"           => 1,   # Max # of modules in chassis
        "maxPortsPerModule"     => 128, # Max # of ports in any module
        "bitmaskBitsPerModule"  => 1024, # Number of bits per module
    },
};

# XXX - The static offset approach appears to be unrealiable, so we look up
# the ifindex using the "ifDescr" table.  Each vlan has an "interface" listed
# there.
#
# Force10 calculates ifIndex for VLANs as 0b10_0001_0000001_1110_00000000000000 + 802.1Q VLAN tag number
#
#my $vlanNumberToIfindexOffset = 1107787776;

#
# Force10 FTOS-EF-7.4.2.3 cannot set purely numeric administrative VLAN names (dot1qVlanStaticName) (by design...)
# So we prepend some alphabetical characters when setting, end strip them when getting
#
my $vlanStaticNamePrefix = "emuID";

# Enterprise OIDs for port aggregations
my $OID_AGGINDEX = ".1.3.6.1.4.1.6027.3.2.1.1.1.1.3";
my $OID_AGGPLIST = ".1.3.6.1.4.1.6027.3.2.1.1.1.1.6";

#
# Ports can be passed around in three formats:
# ifindex : positive integer corresponding to the interface index
#           (eg. 311476282 for gi 8/35)
# modport : dotted module.port format, following the physical reality of
#           Force10 switches (eg. 5/42)
# nodeport: node:port pair, referring to the node that the switch port is
# 	        connected to (eg. "pc42:1")
#
# See the function convertPortFormat below for conversions between these
# formats
#
my $PORT_FORMAT_IFINDEX  = 1;
my $PORT_FORMAT_MODPORT  = 2;
my $PORT_FORMAT_PORT     = 3;

#
# Creates a new object.
#
# usage: new($classname,$devicename,$debuglevel,$community)
#        returns a new object, blessed into the snmpit_force10 class.
#
sub new($$$;$) {

    # The next two lines are some voodoo taken from perltoot(1)
    my $proto = shift;
    my $class = ref($proto) || $proto;

    my $name = shift;                       # the name of the switch, e.g. e1200a
    my $debugLevel = shift;
    my $community = shift;

    #
    # Create the actual object
    #
    my $self = {};

    #
    # Set the defaults for this object
    # 
    if (defined($debugLevel)) {
		$self->{DEBUG} = $debugLevel;
    } else {
		$self->{DEBUG} = 0;
    }
    $self->{BLOCK} = 1;
    $self->{CONFIRM} = 1;
    $self->{NAME} = $name;

    # List of ports in trunk mode - used as a secondary check.
    $self->{TRUNKS} = {};

    #
    # Get config options from the database
    #
    my $options = getDeviceOptions($self->{NAME});
    if (!$options) {
		warn "ERROR: Getting switch options for $self->{NAME}\n";
		return undef;
    }

    $self->{MIN_VLAN}         = $options->{'min_vlan'};
    $self->{MAX_VLAN}         = $options->{'max_vlan'};

    if ($community) { # Allow this to over-ride the default
		$self->{COMMUNITY}    = $community;
    } else {
		$self->{COMMUNITY}    = $options->{'snmp_community'};
    }

    #
    # Get devicetype from database
    #
    my $devicetype = getDeviceType($self->{NAME});
    $self->{TYPE}=$devicetype;

    #
    # set up hashes for pending vlans
    #
    $self->{IFINDEX} = {};     # Used for converting modport to ifIndex (somtimes called iid; e.g. 345555002) and vice versa
    $self->{PORTINDEX} = {};   # Will contain elements for experimental "interfaces" only (no VLANs, no Mgmgnt ifaces); format: ifIndex => ifDescr
    $self->{POIFINDEX} = {};   # Port channel ifindex map.

    if ($self->{DEBUG}) {
		print "snmpit_force10 module initializing... debug level $self->{DEBUG}\n";
    }


    #
    # Set up SNMP module variables, and connect to the device
    #
    $SNMP::debugging = ($self->{DEBUG} - 2) if $self->{DEBUG} > 2;
    my $mibpath = '/usr/local/share/snmp/mibs';
    &SNMP::addMibDirs($mibpath);
    &SNMP::addMibFiles("$mibpath/SNMPv2-SMI.txt", "$mibpath/SNMPv2-TC.txt", 
	               "$mibpath/SNMPv2-MIB.txt", "$mibpath/IANAifType-MIB.txt",
		       "$mibpath/IF-MIB.txt",
		       "$mibpath/SNMP-FRAMEWORK-MIB.txt",
		       "$mibpath/SNMPv2-CONF.txt",
		       "$mibpath/BRIDGE-MIB.txt",
		       "$mibpath/P-BRIDGE-MIB.txt",
		       "$mibpath/Q-BRIDGE-MIB.txt",
		       "$mibpath/EtherLike-MIB.txt");
    $SNMP::save_descriptions = 1; # must be set prior to mib initialization
    SNMP::initMib();		  # parses default list of Mib modules 
    $SNMP::use_enums = 1;	  # use enum values instead of only ints

    warn ("Opening SNMP session to $self->{NAME}...") if ($self->{DEBUG});

    $self->{SESS} = new SNMP::Session(DestHost => $self->{NAME},Version => '2c',
				      Timeout => 4000000, Retries=> 12,
				      Community => $self->{COMMUNITY});

    if (!$self->{SESS}) {
	#
	# Bomb out if the session could not be established
	#
	warn "ERROR: Unable to connect via SNMP to $self->{NAME}\n";
	return undef;
    }

    # Grab our expect object (Ugh... Why Force10, why?)
    # This does not immediately connect to the switch.
    if (exists($options->{"username"}) && exists($options->{"password"})) {
	my $swcreds = $options->{"username"} . ":" . $options->{"password"};
	$self->{EXP_OBJ} = force10_expect->new($self->{NAME},$debugLevel,
					       $swcreds);
	if (!$self->{EXP_OBJ}) {
	    warn "Could not create Expect object for $self->{NAME}\n";
	    return undef;
	}
    } else {
	warn "WARNING: No credentials found for force10 switch $self->{NAME}\n";
	warn "\tPortchannel manipulation will not be possible!\n";
    }

    #
    # Connecting an SNMP session doesn't necessarily mean you can actually get
    # packets to and from the switch. Test that by grabbing an OID that should
    # be on every switch. Let it retry a bunch, to hide transient failures
    #
    my $OS_details = snmpitGetFatal($self->{SESS},["sysDescr",0],30);
    print "Switch $self->{NAME} is running $OS_details\n" if $self->{DEBUG};

    #
    # The bless needs to occur before readifIndex(), since it's a class 
    # method
    #
    bless($self,$class);

    if (!$self->readifIndex()) {
	warn "ERROR: Unable to process ifindex table on $self->{NAME}\n";
	return undef;
    }
    
    return $self;
}

#
# Prints out a debugging message, but only if debugging is on. If a level is
# given, the debuglevel must be >= that level for the message to print. If
# the level is omitted, 1 is assumed
#
# Usage: debug($self, $message, $level)
#
sub debug($$;$) {
    my $self = shift;
    my $string = shift;
    my $debuglevel = shift;
    if (!(defined $debuglevel)) {
	    $debuglevel = 1;
    }
    if ($self->{DEBUG} >= $debuglevel) {
	    print STDERR $string;
    }
}

##############################################################################
## Internal / Utility Functions Section
##

#
# Reads the IfIndex table from the switch, for SNMP functions that use 
# IfIndex rather than the module.port style. Fills out the objects IFINDEX
# and PORTINDEX members
#
# usage: readifIndex(self)
#        returns nothing but sets instance variable IFINDEX
#
sub readifIndex($) {
    my $self = shift;
    my $id = "$self->{NAME}::readifIndex()";
    $self->debug("$id:\n",2);
        
    my ($rows) = snmpitBulkwalkFatal($self->{SESS},["ifDescr"]);
    
    if (!$rows || !@{$rows}) {
	warn "$id: ERROR: No interface description rows returned ".
	     "while attempting to build ifindex table.\n";
	return 0;
    }

    foreach my $result (@{$rows}) {
	my ($name,$iid,$descr) = @{$result};
	$self->debug("got $name, $iid, descr $descr\n",2);
	if ($name ne "ifDescr") {
	    warn "$id: WARNING: Foreign snmp var returned: $name";
	    return 0;
	}
	
	# will match "GigabitEthernet 9/47" but not "Vlan 123"
	if ($descr =~ /(\w*)\s*(\d+)\/(\d+)\/?(\d+)?$/) {
	    my $type = $1;
	    my $module = $2;
	    my $port = defined($4) ? $4 : $3;
	    # Note: Force10 modules and ports start at 0 instead of 1.
	    my $modport = "${module}.${port}";
	    my $ifIndex = $iid;
	    
	    # exclude e.g. ManagementEthernet ports
	    if ( $descr !~ /management/i) {
		$self->{IFINDEX}{$modport} = $ifIndex;
		$self->{IFINDEX}{$ifIndex} = $modport;
		$self->{PORTINDEX}{$ifIndex} = $descr;
		$self->debug("mod $module, port $port, modport $modport, descr $descr\n",2);
	    }
	}
	elsif ($descr =~ /port-channel (\d+)/i) {
	    my $ifIndex = $iid;
	    my $poNum = $1;
	    $self->{POIFINDEX}{$ifIndex} = "Po$poNum";
	    $self->{POIFINDEX}{"Po$poNum"} = $ifIndex;
	    $self->debug("Port-channel $poNum, ifindex $ifIndex\n",2);
	}
    }

    # success
    return 1;
}

#
# Convert a set of ports to an alternate format. The input format is detected
# automatically. See the declarations of the constants at the top of this
# file for a description of the different port formats.
#
# usage: convertPortFormat($self, $output format, @ports)
#        returns a list of ports in the specified output format
#        returns undef if the output format is unknown
#
# TODO: Add debugging output, better comments, more sanity checking
#
sub convertPortFormat($$@) {
    my $self = shift;
    my $output = shift;
    my @ports = @_;
    my $id = "$self->{NAME}::convertPortFormat()";

    #
    # Avoid warnings by exiting if no ports given
    # 
    if (!@ports) {
		return ();
    }

    #
    # We determine the type by sampling the first port given
    #
    my $sample = $ports[0];
    if (!defined($sample)) {
		warn "$id: ERROR: Given a bad list of ports\n";
		return undef;
    }

    my $input;
    SWITCH: for ($sample) {
	(Port->isPort($_)) && do { $input = $PORT_FORMAT_PORT; last; };
	(/^\d+$/) && do { $input = $PORT_FORMAT_IFINDEX; last; };
	(/^\d+\.\d+$/) && do { $input = $PORT_FORMAT_MODPORT; last; };
	warn "$id: ERROR: Unrecognized input sample: $sample\n";
	return undef;
    }

    #
    # It's possible the ports are already in the right format
    #
    if ($input == $output) {
	$self->debug("Not converting, input format = output format\n",2);
	return @ports;
    }

    if ($input == $PORT_FORMAT_IFINDEX) {
	if ($output == $PORT_FORMAT_MODPORT) {
	    $self->debug("Converting ifindex to modport\n",2);
	    return map $self->{IFINDEX}{$_}, @ports;
	} elsif ($output == $PORT_FORMAT_PORT) {
	    $self->debug("Converting ifindex to Port\n",2);
	    return map {Port->LookupByStringForced(
			    Port->Tokens2TripleString(
				$self->{NAME},
				split(/\./,$self->{IFINDEX}{$_})))} @ports;
	}
    } elsif ($input == $PORT_FORMAT_MODPORT) {
	if ($output == $PORT_FORMAT_IFINDEX) {
	    $self->debug("Converting modport to ifindex\n",2);
	    return map $self->{IFINDEX}{$_}, @ports;
	} elsif ($output == $PORT_FORMAT_PORT) {
	    $self->debug("Converting modport to Port\n",2);
	    return map {Port->LookupByStringForced(
			    Port->Tokens2TripleString(
				$self->{NAME},
				split(/\./,$_)))} @ports;
	}
    } elsif ($input == $PORT_FORMAT_PORT) {
	if ($output == $PORT_FORMAT_IFINDEX) {
	    $self->debug("Converting Port to ifindex\n",2);
	    return map $self->{IFINDEX}{$_->switch_card() .".". 
					$_->switch_port()}, @ports;
	} elsif ($output == $PORT_FORMAT_MODPORT) {
	    $self->debug("Converting Port to modport\n",2);
	    return map $_->switch_card() .".". $_->switch_port(), @ports;
	}
    }

    #
    # Some combination we don't know how to handle
    #
    warn "$id: ERROR: Bad input/output combination ($input/$output)\n";
    return undef;
}

#
# Internal function which converts a bitmask (a binary string) to a list 
# of switch ports (ifIndexes)
#
sub convertBitmaskToIfindexes($$) {
    my $self = shift;
    my $bitmask = shift;
    my $id = "$self->{NAME}::convertBitmaskToIfindexes()";

    # Store switch config in local vars for code readability
    my $type                 = $self->{TYPE};
    my $moduleSlots          = $ChassisInfo->{$type}->{moduleSlots};
    my $maxPortsPerModule    = $ChassisInfo->{$type}->{maxPortsPerModule};
    my $bitmaskBitsPerModule = $ChassisInfo->{$type}->{bitmaskBitsPerModule};

    my @ifIndexes;
                                                          
    # start at module 0
    my $mod = 0;                                          
    while ($mod < $moduleSlots) {
        # start at port 0
        my $port = 0;

        # loop over until maxports.  Not usefull to loop over
        # the padding bits, cause some switches use _a lot_ of
        # these bits !!
        while ($port < $maxPortsPerModule) {

            my $offset = 
                # start index for first port of the module
                $mod * $bitmaskBitsPerModule
                # start index for first port of the block of 8
                # ports containing the current port
                + (int($port / 8) * 8)
                # the offset we're actually looking for
                + (7 - ($port % 8));

            if ( vec($bitmask,$offset,1) ) { 
                push @ifIndexes, $self->{IFINDEX}{"${mod}.${port}"};
            }
            $port++;
        }
        $mod++;
    }

    return \@ifIndexes;
}

#
# Internal function which converts a list of switch ports (ifIndexes) to a
# bitmask (a binary string)
#
sub convertIfindexesToBitmask($@) {
    my $self = shift;
    my $ifIndexes = shift;
    my $id = "$self->{NAME}::convertIfindexesToBitmask()";

    # Store switch config in local vars for code readability
    my $type                 = $self->{TYPE};
    my $moduleSlots          = $ChassisInfo->{$type}->{moduleSlots};
    my $maxPortsPerModule    = $ChassisInfo->{$type}->{maxPortsPerModule};
    my $bitmaskBitsPerModule = $ChassisInfo->{$type}->{bitmaskBitsPerModule};

    # initialize ( to avoid perl warnings )
    my $bitmask = 0b0;
    # Overwrite our bitmask with zeroes
    for my $offset (0..($bitmaskBitsPerModule*$moduleSlots+7)) {
        vec($bitmask, $offset, 1) = 0b0;
    }

    # Convert all ifIndexes to modport format and parse modport information
    # to find out vec() offset and set the right bit
    my @modports = $self->convertPortFormat($PORT_FORMAT_MODPORT,@$ifIndexes);

    foreach my $modport (@modports) {
        $modport =~ /(\d+)\.(\d+)/;
        my $mod  = $1;
        my $port = $2;


	$self->debug("$id: modport $modport\n");

        if ( $port >= $maxPortsPerModule )
        {
            warn "$id: WARNING: Cannot set port larger than maxport.\n";
            next;
        }

        
        my $offset = 
            # start index for first port of the module
            $mod * $bitmaskBitsPerModule
            # start index for first port of the block of 8
            # ports containing the current port
            + (int($port / 8) * 8)
            # the offset we're actually looking for
            + (7 - ($port % 8));

        vec($bitmask, $offset, 1) = 0b1;
    }
    
    # All set!
    return $bitmask;
}

#
# Internal function which compares two bitmasks of equal length
# and returns the number of differing bits
#
# usage: bitmasksDiffer($bitmask1, $bitmask2) 
#
sub bitmasksDiffer($$$) {
	my $self = shift;
	my $bm1 = shift;
	my $bm2 = shift;
	
	my $id = "$self->{NAME}::bitmasksDiffer()";
	
	my $differingBits = 0;
	my $bm1unp = unpack('B*', $bm1);
	my @bm1unp = split //, $bm1unp; 
	my $bm2unp = unpack('B*', $bm2);
	my @bm2unp = split //, $bm2unp;
	
	if ( $#bm1unp == $#bm2unp ) { # must be of equal length
		for my $i (0 .. $#bm1unp) {
			if ($bm1unp[$i] != $bm2unp[$i]) {
				$self->debug("$id: bit with index $i differs!\n");
				$differingBits++;
			}
		}

		return $differingBits;
	}
	else {
		warn "$id: WARNING: bitmasks to compare have ".
		     "differing length: \$bm1 has last index $#bm1unp ".
		     "and \$bm2 has last index $#bm2unp\n";
		return ( $#bm1unp > $#bm2unp ? $#bm1unp : $#bm2unp);
	}
}

#
# Internal function which checks if all set bits in a bitmask are set or not in
# another one. Both bitmasks must be of equal length.
# 
# Returns 0 if all bits of interest conform, otherwise returns the number of
# non-conforming bits
#
# usage: checkBits($requestedStatus, $bitsOfInterest, $bitmaskToInvestigate)
#        $requestedStatus can be "on" or "off"
#
sub checkBits($$$$) {
    my $self = shift;
    my $reqStatus = shift;
    my $bm1 = shift; # reference bitmask, defining which bits need to be checked
    my $bm2 = shift; # bitmask to investigate

    my $id = "$self->{NAME}::checkBits()";
    
    my $differingBits = 0;
    my $bm1unp = unpack('B*', $bm1);
    my @bm1unp = split //, $bm1unp; 
    my $bm2unp = unpack('B*', $bm2);
    my @bm2unp = split //, $bm2unp;
    
    if ( $#bm1unp == $#bm2unp ) { # must be of equal length
	if ($reqStatus eq "on") {
	    for my $i (0 .. $#bm1unp) {
		if ($bm1unp[$i]) { # if bit is set
   		    $self->debug("checkBits(\"on\"): bit with index $i is set!\n");

		    if ($bm1unp[$i] != $bm2unp[$i]) {
			$self->debug("checkBits(\"on\"): bit with index $i isn't set in the other bitmask, while it should be!\n");
			$differingBits++;
		    }
		}
	    }
	} elsif ($reqStatus eq "off") {
	    for my $i (0 .. $#bm1unp) {
		if ($bm1unp[$i]) { # if bit is set
		    if ($bm1unp[$i] == $bm2unp[$i]) {
			$self->debug("checkBits(\"off\"): bit with index $i is set in the other bitmask, while it shouldn't be!\n");
			$differingBits++;
		    }
		}
	    }			
	} else {
	    warn "$id: ERROR: invalid requested status argument: $reqStatus\n";
	    return ($#bm1unp + 1);
	}
	
	return $differingBits;
    } else {
	warn "$id: ERROR: input bitmasks are of differing length!\n";
	$self->debug("$id: \$bm1 has last index $#bm1unp and \$bm2 has last index $#bm2unp\n");
	return ( $#bm1unp > $#bm2unp ? $#bm1unp + 1 : $#bm2unp + 1);
    }
}

# Utility function to add a static string prefix to an Emulab vlan id.
# FTOS does not allow purely numeric vlan names.
sub stripVlanPrefix($) {
    my $vlname = shift;

    if ($vlname =~ /^$vlanStaticNamePrefix(\d+)$/) {
	return $1;
    } else {
	return $vlname;
    }
}

# Utility function to strip the static string prefix from a vlan name,
# giving the original Emulab vlan id.
sub addVlanPrefix($) {
    my $vlname = shift;
    
    return $vlanStaticNamePrefix.$vlname;
}


# Utility function for looking up ifindex for a vlan
# usage: getVlanIfindex($self,$vlan_number)
#        $self - reference to "this" object
#        $vlan_number - native switch vlan number to lookup (vlan tag)
# returns: the ifindex of given vlan number, or a hash with all vlans if
#          the keyword "ALL" is given.  undef on failure / not found.
sub getVlanIfindex($$) {
    my ($self, $vlan_number) = @_;
    my $id = "$self->{NAME}::getVlanIfindex()";

    my %results = ();
    my ($rows) = snmpitBulkwalkFatal($self->{SESS},["ifDescr"]);
    
    if (!$rows || !@{$rows}) {
	warn "$id: ERROR: No interface description rows returned (snmp).";
	return undef;
    }

    foreach my $result (@{$rows}) {
	my ($name,$iid,$descr) = @{$result};

	next unless $descr =~ /vlan\s+(\d+)/i;
	my $curvlnum = $1;

	$self->debug("$id: got $name, $iid, descr $descr\n",2);

	if ($vlan_number eq "ALL") {
	    $results{$iid} = $curvlnum;
	}
	elsif ($curvlnum == $vlan_number) {
	    return $iid;
	}
    }

    if ($vlan_number eq "ALL") {
	return %results;
    }

    # Not found.
    return undef;
}

# Utility function that grabs the port membership bitmask for a vlan.
# usage: getMemberBitmask($self, $vlan_ifindex)
# returns: bitmask as returned from switch via snmp (packed vector), 
#          or undef on failure.
sub getMemberBitmask($$;$) {
    my ($self, $vlidx, $both) = @_;
    my $id = "$self->{NAME}::getMemberBitmask()";

    my $ebitmask = snmpitGetWarn($self->{SESS},["dot1qVlanStaticEgressPorts",
						$vlidx]);
    my $ubitmask = snmpitGetWarn($self->{SESS},["dot1qVlanStaticUntaggedPorts",
						$vlidx]);

    if (!$ebitmask || !$ubitmask) {
	warn "$id: ERROR: problem fetching current membership bitmask for vlan with ifindex $vlidx\n";
	return undef;
    }

    if ($both) {
	return ($ebitmask, $ubitmask);
    }

    return $ebitmask;
}

#
# Utility function to punch in the egress and untagged port memberships
# for the given vlan number (tag).  $onoff tells the function how to check
# the resulting membership list ("on" - add; "off" - remove).
#
# usage: setPortMembership($self, $onoff, $eportmask, $uportmask, $vlifindex)
#        $self - reference to "this" object.
#        $onoff - check for addition ("on") or removal ("off") ports.
#        $eportmask - packed bitmask to use with dot1qVlanStaticEgressPorts
#        $uportmask - packed bitmask to use with dot1qVlanStaticUntaggedPorts
#        $vlifindex - ifindex of vlan to operate on.
#
# returns: number of ports that failed to be (un)set.
#
sub setPortMembership($$$$$) {
        my ($self, $onoff, $eportmask, $uportmask, $vlifindex) = @_;
	my $id = "$self->{NAME}::setPortMembership()";

	# Sanity checks
	if (!defined($onoff) || !defined($eportmask) || 
	    !defined($uportmask) || !defined($vlifindex)) {
	    warn "$id: ERROR: required parameters missing to call.";
	    return -1;
	}

	if (length($eportmask) != length($uportmask)) {
	    warn "$id: ERROR: egress and untagged portsets are different sizes!";
	    return -1;
	}

	if ($onoff ne "on" && $onoff ne "off") {
	    warn "$id: \$onoff must be either 'on' or 'off'";
	    return -1;
	}

	if ($vlifindex !~ /^\d+$/) {
	    warn "$id: vlan ifindex is not a number: $vlifindex\n";
	    return -1;
	}

	# Grab the number of bits set in the untagged port mask.
	my $setcount = unpack("%32b*", $uportmask);

	$self->debug("$id: Setting membership for vlan with ".
		     "ifindex $vlifindex\n");
	$self->debug("$id: Validate membership state to be: $onoff\n");

	# The egress ports and untagged ports have to be updated
	# simultaneously.
	my $snmpvars = new SNMP::VarList(
	    ["dot1qVlanStaticEgressPorts", $vlifindex, 
	     $eportmask, "OCTETSTR"], 
	    ["dot1qVlanStaticUntaggedPorts", $vlifindex, 
	     $uportmask, "OCTETSTR"]);

	# XXX: Can't use snmpitSetWarn since these port set operations
	# routinely return an "undoFailed" status on the Force10
	# platform (even when successful).  Not sure why this happens...
	my $status = $self->{SESS}->set($snmpvars);

	# Since the return value cannot be trusted, we do our own
	# little investigation to see if the set command succeeded.
	if (!defined($status)) {
	    $self->debug("$id: Error setting port membership: $self->{SESS}->{ErrorStr}\n");
	}

	# Get the current membership bitmask for this vlan
	my $newmask = $self->getMemberBitmask($vlifindex);
	if (!defined($newmask)) {
		warn "$id: ERROR: failed to get current ".
		     "membership bitmask for vlan with ifindex $vlifindex\n";
		return $setcount;
	}
	
	# Should return 0 if everything is alright, no. of failed
	# ports otherwise
	my $checkmask = $onoff eq "on" ? $eportmask : $uportmask;
	my $failcount = $self->checkBits($onoff, $checkmask, 
					 $newmask);

	if ($failcount) {
		warn "$id: Could not manipulate $failcount ".
		     "ports in vlan with ifindex $vlifindex!\n";
	}

	return $failcount; # should be 0
}

# Remove the input ports from any VLAN they might be in, except for the
# default vlan.
sub removePortsFromAllVlans($$@) {
    my ($self, $tagged_only, @ports) = @_;
    my $id = "$self->{NAME}::removePortsFromAllVlans";
    my $errors = 0;

    $self->debug("$id: entering\n");

    # Bail now if the list of ports is empty.
    if (!@ports) {
	$self->debug("$id: called with empty port list... ".
		     "Returning success!\n");
	return 0;
    }

    my @ifindexes = $self->convertPortFormat($PORT_FORMAT_IFINDEX, @ports);
    my $portmask = $self->convertIfindexesToBitmask(\@ifindexes);
    my %vlifindexes = $self->getVlanIfindex("ALL");
    while (my ($vlifidx, $vlnum) = each %vlifindexes) {
        $self->debug("$id: Attempting to remove @ports from ".
			 "vlan number $vlnum\n");
	# vlan 1 is the default vlan; we don't touch it in removal
	# operations.  Membership in the default vlan is handled
	# automagically on the Force10 platform.
	next if ($vlnum == 1);

	# Only attempt a removal operation if any of the ports appear
	# in the current member list.  If only removal of tagged ports
	# was requested, adjust the mask to check against accordingly.
	my ($emask, $umask) = $self->getMemberBitmask($vlifidx,1);
	my $checkmask = $emask;
	my $rmports = \@ports;
	if ($tagged_only) {
	    # see comments in removeSomePortsFromVlan()
	    $checkmask = $portmask & ($emask ^ $umask);
	    $rmports = $self->convertBitmaskToIfindexes($checkmask);
	} 
	if ($self->checkBits("off", $portmask, $checkmask)) {
	    $self->debug("$id: Attempting to remove @ports from ".
			 "vlan number $vlnum\n");
	    $errors += $self->removeSomePortsFromVlan($vlnum, @{$rmports});
	}
    }

    return $errors;
}

##############################################################################
## Snmpit API Module Methods Section
##

#
# List all ports on the device
#
# usage: listPorts($self)
# see snmpit_cisco_stack.pm for a description of return value format
#
#
sub listPorts($) {
    my $self = shift;
    my $id = "$self->{NAME}::listPorts()";

    my %Nodeports = ();
    my %Able = ();
    my %Link = ();
    my %speed = ();
    my %duplex = ();

    my ($ifIndex, $status);

    #
    # Get the port configuration, including ifOperStatus (really up or down),
    # duplex, speed / whether or not it is autoconfiguring
    #			
    foreach $ifIndex (keys %{$self->{PORTINDEX}}) {

	#
	# Skip ports that don't seem to have anything interesting attached
	#
	my ($port) = $self->convertPortFormat($PORT_FORMAT_PORT, $ifIndex);
	my $nodeport = $port->getOtherEndPort();
	if (!defined($port) || !defined($nodeport) || 
	    $port->toString() eq $nodeport->toString()) {
	    $self->debug("Port $port not connected, skipping\n");
	    next;
	}
	$Nodeports{$ifIndex} = $nodeport;

	if ($status = snmpitGetWarn($self->{SESS},["ifAdminStatus",
						   $ifIndex])) {
	    $Able{$ifIndex} = ( $status =~ /up/ ? "yes" : "no" );
	}
    	
	if ($status = snmpitGetWarn($self->{SESS},["ifOperStatus",
						   $ifIndex])) {
	    $Link{$ifIndex} = $status;
	}
		
	if ($status = snmpitGetWarn($self->{SESS},["dot3StatsDuplexStatus",
						   $ifIndex])) {
	    $status =~ s/Duplex//;
	    $duplex{$ifIndex} = $status;
	}
	
	if ($status = snmpitGetWarn($self->{SESS},["ifHighSpeed",
						   $ifIndex])) {
	    $speed{$ifIndex} = $status . "Mbps";
	}
    }
    
    #
    # Put all of the data gathered in the loop into a list suitable for
    # returning
    #
    my @rv = ();
    foreach my $ifIndex ( sort keys %Able ) {
	if (! defined ($speed{$ifIndex}) ) { $speed{$ifIndex} = " "; }
	if (! defined ($duplex{$ifIndex}) ) { $duplex{$ifIndex} = "full"; }
	push @rv, [$Nodeports{$ifIndex},$Able{$ifIndex},$Link{$ifIndex},$speed{$ifIndex},$duplex{$ifIndex}];
    }
    return @rv;
}


#
# List all VLANs on the device
#
# usage: listVlans($self)
# see snmpit_cisco_stack.pm for a description of return value format
#
sub listVlans($) {
	my $self = shift;
	my $id = "$self->{NAME}::listVlans()";
	$self->debug("\n$id:\n",2);
	
	my %Names = ();
	my %Numbers = ();
	my %Members = ();

	# get list of vlan names from dot1qVlanStaticName (Q-BRIDGE-MIB)
	# and save these in %Names with the ifIndexes (iids) as the key
	# (unlike ethernet ports, vlans aren't static, so this is done from
	# scratch each time instead of being stored in a hash by the constructor
	my ($results) = snmpitBulkwalkWarn($self->{SESS}, ["dot1qVlanStaticName"]);

	# $name should always be "dot1qVlanStaticName"
	foreach my $result (@{$results}) {
	    my ($name,$iid,$vlanname) = @{$result};
	    $self->debug("$id: got $name, $iid, name $vlanname\n",2);
	    if ($name ne "dot1qVlanStaticName") {
		warn "$id: WARNING: unexpected oid: $name\n";
		next;
	    }

	    # Must strip the prefix required on the Force10 to get the vlan id
	    # as known by Emulab.
	    $vlanname = stripVlanPrefix($vlanname);
	    $Names{$iid} = $vlanname;
	}
	
	my ($ifIndex, $status);
	
	# get corresponding VLAN numbers
	# (i.e. the "real" vlan tags as known by the switch, called 
	# "cisco-specific" in the snmpit_cisco.pm module;
	# with "vlan id" they mean the vlan name as known in the 
	# database = the administrative name in the switch, not the tag)
	foreach $ifIndex (keys %Names) {
	    if ($status = snmpitGetWarn($self->{SESS},
					["ifDescr",$ifIndex])) {
		if ($status =~ /^Vlan\s(\d+)$/) {
		    $Numbers{$ifIndex} = $1;
		} else {
		    warn "$id: ERROR: Unable to parse out vlan tag for ifindex $ifIndex\n";
		    return undef;
		}
	    } else {
		warn "$id: ERROR: Unable to get vlan tag for ifindex $ifIndex\n";
		return undef;
	    }
	}
	
	# get corresponding port bitmaps from dot1qVlanStaticEgressPorts
	# and find out the corresponding port ifIndexes
	foreach $ifIndex (keys %Names) {
	    my $membermask = $self->getMemberBitmask($ifIndex);
	    if (defined($membermask)) {
		my $indexes = $self->convertBitmaskToIfindexes($membermask);
		my @ports = $self->convertPortFormat($PORT_FORMAT_PORT, 
						     @{$indexes});
		$Members{$ifIndex} = \@ports;
	    } else {
		warn "$id: ERROR: Unable to get port membership for ifindex $ifIndex\n";
		return undef;
	    }
	}
	
	# create array to return to caller
	my @vlanInfo = ();
	foreach $ifIndex (sort {$a <=> $b} keys %Names) {
		push @vlanInfo, [$Names{$ifIndex},$Numbers{$ifIndex},
			$Members{$ifIndex}];
	}
	$self->debug(join("\n",(map {join ",", @$_} @vlanInfo))."\n");
	
	return @vlanInfo;
}

# 
# Check to see if the given "real" VLAN number (i.e. tag) exists on the switch
#
# usage: vlanNumberExists($self, $vlan_number)
#        returns 1 if the 802.1Q VLAN tag exists, 0 otherwise
#
sub vlanNumberExists($$) {
    my ($self, $vlan_number) = @_;

    # resolve the vlan number to an ifindex.  If no result, then no vlan...
    if (defined($self->getVlanIfindex($vlan_number))) {
	return 1;
    } else {
    	return 0;
    }
}

#
# Given VLAN indentifiers from the database, finds the cisco-specific VLAN
# number for them. If not VLAN id is given, returns mappings for the entire
# switch.
# 
# usage: findVlans($self, @vlan_ids)
#        returns a hash mapping VLAN ids to Cisco VLAN numbers
#        any VLANs not found have NULL VLAN numbers
#
sub findVlans($@) {
    my $self = shift;
    my @vlan_ids = @_;
    my %vlanmap = ();
    my $id = "$self->{NAME}::findVlans()";

    # Build a mapping from vlan ifindex to vlan number.  Have to do this
    # each time since the set of vlans varies over time.
    my %vlidx2num = $self->getVlanIfindex("ALL");
    
    # Grab the list of vlans.
    my ($results) = snmpitBulkwalkWarn($self->{SESS}, ["dot1qVlanStaticName"]);

    foreach my $result (@{$results}) {
	my ($name,$iid,$vlanname) = @{$result};
	$self->debug("findVlans(): got $name, $iid, name $vlanname\n",2);
	if ($name ne "dot1qVlanStaticName") {
	    warn "$id: WARNING: unexpected oid: $name\n";
	    next;
	}

	# Must strip the prefix required on the Force10 to get the vlan id
	# as known by Emulab.
	$vlanname = stripVlanPrefix($vlanname);
	
	# add to hash if theres no @vlan_ids list (requesting all) or if the
	# vlan is actually in the list
	if ( (! @vlan_ids) || (grep {$_ eq $vlanname} @vlan_ids) ) {
	    $vlanmap{$vlanname} = $vlidx2num{$iid};
	}
    }

    return %vlanmap;
}

#
# Given a VLAN identifier from the database, find the "cisco-specific VLAN
# number" that is assigned to that VLAN (= VLAN tag). Retries several times (to
# account for propagation delays) unless the $no_retry option is given.
#
# usage: findVlan($self, $vlan_id,$no_retry)
#        returns the VLAN number for the given vlan_id if it exists
#        returns undef if the VLAN id is not found
#
sub findVlan($$;$) { 
    my $self = shift;
    my $vlan_id = shift;
    my $no_retry = shift;
    
    my $max_tries;
    if ($no_retry) {
	$max_tries = 1;
    } else {
	$max_tries = 10;
    }

    # We try this a few times, with 1 second sleeps, since it can take
    # a while for VLAN information to propagate
    foreach my $try (1 .. $max_tries) {

	my %mapping = $self->findVlans($vlan_id);
	if (defined($mapping{$vlan_id})) {
	    return $mapping{$vlan_id};
	}

	# Wait before we try again
	if ($try < $max_tries) {
	    $self->debug("findVlan: failed, trying again\n");
	    sleep 1;
	}
    }

    # Didn't find it
    return undef;
}

#
# Determine if a VLAN has any members 
# (Used by stack->switchesWithPortsInVlan())
#
sub vlanHasPorts($$) {
    my ($self, $vlan_number) = @_;
    my $id = "$self->{NAME}::vlanHasPorts()";

    my $vlifindex = $self->getVlanIfindex($vlan_number);
    if (!defined($vlifindex)) {
	warn "$id: ERROR: Could not lookup vlan index for vlan: $vlan_number\n";
	return 0;
    }

    my $membermask = $self->getMemberBitmask($vlifindex);
    if (!defined($membermask)) {
	warn "$id: ERROR: Could not get membership bitmask for blan: $vlan_number\n";
	return 0;
    }
    my $setcount = pack("%32b*", $membermask);

    return $setcount ? 1 : 0;
}

#
# Create a VLAN on this switch, with the given identifier (which comes from
# the database) and given 802.1Q tag number ($vlan_number). 
#
# usage: createVlan($self, $vlan_id, $vlan_number)
#        returns the new VLAN number on success
#        returns 0 on failure
#
sub createVlan($$$) {
    my $self = shift;
    
    # as known in db and as will be saved in administrative vlan
    # name on switch
    my $vlan_id = shift;

    # 802.1Q vlan tag
    my $vlan_number = shift; 

    my $id = "$self->{NAME}::createVlan()";
	
    # Check to see if the requested vlan number already exists.
    if ($self->vlanNumberExists($vlan_number)) {
	warn "$id: ERROR: VLAN $vlan_number already exists\n";
	return 0;
    }

    # Create VLAN
    my $RetVal = snmpitSetWarn($self->{SESS},["dot1qVlanStaticRowStatus", 
					      $vlan_number, "createAndGo", 
					      "INTEGER"]);
    # $RetVal will be undefined if the set failed, or "1" if it succeeded.
    if (! defined($RetVal) )  { 
	warn "$id: ERROR: VLAN Create id '$vlan_id' as VLAN $vlan_number failed.\n";
	return 0;
    }

    # trying to use static ifindex offsets for vlans is unreliable.
    my $vlifindex = $self->getVlanIfindex($vlan_number);
    if (!defined($vlifindex)) {
	warn "$id: ERROR: Could not lookup ifindex for vlan number: $vlan_number\n";
	return 0;
    }
    
    # Set administrative name to vlan_id as known in emulab db.
    # Prepend a string to the numeric id as Force10 doesn't allow all numberic
    # for a vlan name.
    $vlan_id = addVlanPrefix($vlan_id);
    $RetVal = snmpitSetWarn($self->{SESS},["dot1qVlanStaticName", 
					   $vlifindex,
					   $vlan_id,
					   "OCTETSTR"]);
    
    # $RetVal will be undefined if the set failed, or "1" if it succeeded.
    if (! defined($RetVal) )  { 
	warn "$id: ERROR: Setting VLAN name to '$vlan_id' failed, ".
	     "but VLAN $vlan_number was created! ".
	     "Manual cleanup required.\n";
	return 0;
    }

    return $vlan_number;
}

#
# Put the given ports in the given VLAN. The VLAN is given as an 802.1Q 
# tag number. (so NOT as a vlan_id from the database!)
#
# usage: setPortVlan($self, $vlan_number, @ports)
#	 returns 0 on sucess.
#	 returns the number of failed ports on failure
#
sub setPortVlan($$@) {
    my ($self, $vlan_number, @ports) = @_;
    my $id = "$self->{NAME}::setPortVlan";

    $self->debug("id: entering\n");

    # Get the vlan's ifindex now.  No point in doing anything more if it
    # doesn't exist!
    my $vlanIfindex = $self->getVlanIfindex($vlan_number);
    if (!$vlanIfindex) {
	warn "$id: ERROR: Could not find ifindex for vlan $vlan_number\n";
	return scalar(@ports);
    }

    # Convert the list of input ports into the two formats we need here.
    # Hopefully the incoming list contains port objects already - otherwise
    # we are in for DB queries.
    my @portlist = $self->convertPortFormat($PORT_FORMAT_IFINDEX, @ports);
    my @portobjs = $self->convertPortFormat($PORT_FORMAT_PORT, @ports);
    $self->debug("id: input ports: " . join(",",@ports) . "\n");
    $self->debug("id: as ifIndexes: " . join(",",@portlist) . "\n");

    if (scalar(@portlist) != scalar(@portobjs)) {
	warn "$id: ERROR: Port object list length is different than ifindex list length for the same set of input ports!\n";
	return scalar(@ports);
    }

    # Create a bitmask from this ifIndex list
    my $portmask = $self->convertIfindexesToBitmask(\@portlist);

    # Look at DB state (via Port objects) to determine which ports are
    # in trunk mode.  Create the "untagged" bitmask from those that
    # are not.
    my $i = 0;
    my @uportlist = ();
    my @upobjs = ();
    foreach my $pobj (@portobjs) {
	if ($pobj->tagged() == 0 && 
	    !exists($self->{TRUNKS}->{$portlist[$i]})) {
	    $self->debug("id: Adding port $pobj as untagged to $vlan_number\n",2);
	    push @uportlist, $portlist[$i];
	    push @upobjs, $pobj;
	}
	$i++;
    }
    my $uportmask = $self->convertIfindexesToBitmask(\@uportlist);

    # Zap the untagged ports from any vlan that they are currently in
    # (aside from the default).  Otherwise, the subsequent set operation
    # might fail.
    my $tagged_only = 0;
    $self->removePortsFromAllVlans($tagged_only, @upobjs);

    # Mix in the membership already set up on the target vlan.  Doing this
    # avoids accidentally removing tagged ports when adding new ports to the
    # vlan (zeros written to a port's bit in both vectors will remove it from
    # the vlan if it's a tagged member).
    my ($vlebits, $vlubits) = $self->getMemberBitmask($vlanIfindex,1);
    my $ebits = $portmask | $vlebits;
    my $ubits = $uportmask | $vlubits;

    return $self->setPortMembership("on", $ebits, $ubits, $vlanIfindex);
}

# Removes and disables some ports in a given VLAN. The VLAN is given as a VLAN
# 802.1Q tag value.  Ports are known to be regular ports and not trunked.
#
# usage: removeSomePortsFromVlan(self,vlan,@ports)
#	 returns 0 on sucess.
#	 returns the number of failed ports on failure.
sub removeSomePortsFromVlan($$@) {
	my $self = shift;
	my $vlan_number = shift;
	my @ports = @_;
	my $id = "$self->{NAME}::removeSomePortsFromVlan()";

	# VLAN 1 is default VLAN, that's where all ports are supposed to go
	# so trying to remove them there doesn't make sense
	if ($vlan_number == 1) {
	    warn "$id: WARNING: Attempt made to remove @ports from default VLAN 1\n";
	    return 0;
	}

	# Run the port list through portmap to find the ports on the switch that
	# we are concerned with
	my @portlist = $self->convertPortFormat($PORT_FORMAT_IFINDEX, @ports);
	$self->debug("$id: removing ports from vlan $vlan_number: @ports\n");
	$self->debug("$id: port ifIndexes: @portlist\n");
	
	# Create a bitmask from this ifIndex list
	my $bitmaskToRemove = $self->convertIfindexesToBitmask(\@portlist);

	# Create an all-zero bitmask of the appropriate length.
	my $allZeroBitmask = "00000000" x length($bitmaskToRemove);
        $allZeroBitmask = pack("B*", $allZeroBitmask);

	# Get the vlan's ifindex.
	my $vlanIfindex = $self->getVlanIfindex($vlan_number);
	if (!defined($vlanIfindex)) {
	    warn "$id: ERROR: Could not get ifindex for vlan number $vlan_number!\n";
	    return scalar(@ports);
	}

	# Warning - wacky bitmath ahead! Removing a port from a vlan is
	# done differently for tagged vs. untagged ports.  To remove a tagged
	# port, the port's bit needs to be '0' in both egress and untagged
	# PortSets.  To remove an untagged port, the port's egress bit must
	# be a '0', while the untagged bit must be a '1'.  Gross.
	my ($curEbits, $curUbits) = $self->getMemberBitmask($vlanIfindex,1);
	# The set of currently tagged ports have a '1' in the egress
	# PortSet and a '0' in the untagged PortSet.  Tagged ports
	# have a '1' in both sets, and non-members are '0' in both. XOR!
	my $tagBits = $curEbits ^ $curUbits;
	# Set the egress PortSet to zeros where we are removing ports, but
	# set to '1' for tagged ports that are not to be removed. gawd.
	my $eBits = ($bitmaskToRemove & $tagBits) ^ $tagBits;
	# To create the untagged PortSet, we clear the tagged port
	# bits in the input PortSet, leaving just the untagged ports
	# with their bits set.
	my $uBits = $curUbits & $bitmaskToRemove;

	return $self->setPortMembership("off", $eBits, $uBits, $vlanIfindex);
}


#
# Remove the given VLANs from this switch. Removes all ports from the VLAN,
# so it's not necessary to call removePortsFromVlan() first. The VLAN is
# given as a 802.1Q VLAN tag number (so NOT as a vlan_id from the database!)
#
# usage: removeVlan(self,int vlan)
#	 returns 1 on success
#	 returns 0 on failure
#
sub removeVlan($@) {
	my $self = shift;
	my @vlan_numbers = @_;
	my $errors = 0;
	my $DeleteOID = "dot1qVlanStaticRowStatus";
	my $id = "$self->{NAME}::removeVlan()";

	foreach my $vlan_number (@vlan_numbers) {
	        # We won't remove vlan 1.
	        next if $vlan_number == 1;
		# Calculate ifIndex for this VLAN
		my $ifIndex = $self->getVlanIfindex($vlan_number);
		if (!defined($ifIndex)) {
		    warn "$id: ERROR: Problem looking up vlan ifindex for vlan number $vlan_number.\n";
		    $errors++;
		    next;
		}
		
		# Perform the actual removal (no need to first remove all ports from
		# the VLAN)
		
		my $RetVal = undef;
		print "  Removing VLAN # $vlan_number ... ";
		$RetVal = snmpitSetWarn($self->{SESS},
				[$DeleteOID,$ifIndex,"destroy","INTEGER"]);
		# $RetVal should contain "0 but true" if successful	
		if ( defined($RetVal) ) { 
			print "Removed VLAN $vlan_number on switch $self->{NAME}.\n";
		} else {
		    warn "$id: ERROR: Removal of VLAN $vlan_number failed.\n";
		    $errors++;
		    next;
		}
	}
	
	return ($errors == 0) ? 1 : 0;
}

#
# Removes ALL ports from the given VLANS. Each VLAN is given as a VLAN
# 802.1Q tag value.
#
# usage: removePortsFromVlan(self,@vlan)
#	 returns 0 on sucess (!!!)
#	 returns the number of failed ports on failure.
#
sub removePortsFromVlan($@) {
    my $self = shift;
    my @vlan_numbers = @_;
    my $errors = 0;
    my $id = "$self->{NAME}::removePortsFromVlan()";

    foreach my $vlan_number (@vlan_numbers) {
    	$self->debug("$id: attempting to remove all ports from vlan_number $vlan_number\n");
    	
	# VLAN 1 is default VLAN, that's where all ports are supposed to go
	# so trying to remove them there doesn't make sense
	if ($vlan_number == 1) {
	    warn "$id: WARNING: Attempt made to remove all ports from default VLAN 1\n";
	    next;
	}

	# Get the ifindex of the vlan.
	my $vlanIfindex = $self->getVlanIfindex($vlan_number);
	if (!defined($vlanIfindex)) {
	    warn "$id: WARNING: Could not get ifindex for vlan number $vlan_number!\n";
	    next;
	}
	
	# Get the current membership bitmask and convert to a list of
	# port ifindexes to pass to removeSomePortsFromVlan()
	my $currentBitmask = $self->getMemberBitmask($vlanIfindex);
	my $portlist = $self->convertBitmaskToIfindexes($currentBitmask);
	$errors += $self->removeSomePortsFromVlan($vlan_number, @{$portlist});
    }

    return $errors;
}

#
# Set a variable associated with a port. The commands to execute are given
# in the cmdOIDs hash above. A command can involve multiple OIDs.
#
# usage: portControl($self, $command, @ports)
#    returns 0 on success.
#    returns number of failed ports on failure.
#    returns -1 if the operation is unsupported
#
sub portControl ($$@) {
	my $self = shift;
	my $cmd = shift;
	my @ports = @_;
	my $id = "$self->{NAME}::portControl()";

	$self->debug("$id: $cmd -> (@ports)\n");

	# Find the command in the %cmdOIDs hash (defined at the top of this file)
	if (defined $cmdOIDs{$cmd}) {
		my @oid = @{$cmdOIDs{$cmd}};
		my $errors = 0;

		# Convert the ports from the format they were given in to the format
		# required by the command... and probably FTOS will always require
		# ifIndexes.
		
		my $portFormat = $PORT_FORMAT_IFINDEX;
		my @portlist = $self->convertPortFormat($portFormat,@ports);

		# Some commands involve multiple SNMP commands, so we need to make
		# sure we get all of them
		while (@oid) {
			my $myoid = shift @oid;
			my $myval = shift @oid;

			$errors += $self->UpdateField($myoid,$myval,@portlist);
		}
		return $errors;
	} else {
		# Command not supported
		$self->debug("$id: Unsupported port control command ".
			     "'$cmd' ignored.\n");
		return -1;
	}
}

#
# Sets a *single* OID to a desired value for a given list of ports (in ifIndex format)
#
# usage: UpdateField($self, $OID, $desired_value, @ports)
#    returns 0 on success
#    returns -1 on failure
#
sub UpdateField($$$@) {
	my $self = shift;
	my ($OID,$val,@ports)= @_;

	$self->debug("UpdateField(): OID $OID value $val ports @ports\n");

	my $RetVal = 0;
	my $result = 0;

    foreach my $port (@ports) {
		$self->debug("UpdateField(): checking port $port for $OID $val ...\n");
		$RetVal = snmpitGetWarn($self->{SESS},[$OID,$port]);
		if (!defined $RetVal) {
			$self->debug("UpdateField(): Port $port, change to $val: ".
				"No answer from device\n");
			$result = -1;
		} else {
			$self->debug("UpdateField(): Port $port was $RetVal\n");
			if ($RetVal ne $val) {
				$self->debug("UpdateField(): Setting port $port to $val...\n");
				$RetVal = snmpitSetWarn($self->{SESS},[$OID,$port,$val,"INTEGER"]);

				my $count = 6;
				while (($RetVal ne $val) && (--$count > 0)) { 
					sleep 1;
					$RetVal = snmpitGetWarn($self->{SESS},[$OID,$port]);
					$self->debug("UpdateField(): Value for port $port is ".
						"currently $RetVal\n");
				}
				$result =  ($count > 0) ? 0 : -1;
				$self->debug("UpdateField(): ".
					($result ? "failed.\n" : "succeeded.\n") );
			}
		}
	}
	return $result;
}

# 
# Get statistics for ports on the switch
#
# usage: getPorts($self)
# see snmpit_cisco_stack.pm for a description of return value format
#
#
sub getStats() {
    my $self = shift;

    #
    # Walk the tree for the VLAN members
    #
    my $vars = new SNMP::VarList(['ifInOctets'],['ifInUcastPkts'],
    				 ['ifInNUcastPkts'],['ifInDiscards'],
				 ['ifInErrors'],['ifInUnknownProtos'],
				 ['ifOutOctets'],['ifOutUcastPkts'],
				 ['ifOutNUcastPkts'],['ifOutDiscards'],
				 ['ifOutErrors'],['ifOutQLen']);
    my @stats = $self->{SESS}->bulkwalk(0,32,$vars);

    my $i = 0;
    my %stats = ();
    my %allports = ();
    foreach my $array (@stats) {
	while (@$array) {
	    my ($name,$ifindex,$value) = @{shift @$array};

	    # filter out entries we don't care about.
            if (! defined $self->{IFINDEX}{$ifindex}) { next; }

	    # Convert to Port object, check connectivity, and stash metrics.
            my ($swport) = $self->convertPortFormat($PORT_FORMAT_PORT, 
						    $ifindex);
            if (! defined $swport) { next; } # Skip if we don't know about it
            my $nportstr = $swport->getOtherEndPort()->toTripleString();
            $allports{$nportstr} = $swport;
	    ${$stats{$nportstr}}[$i] = $value;
	}
	$i++;
    }

    return map [$allports{$_},@{$stats{$_}}], sort {tbsort($a,$b)} keys %stats;
}

#
# Read a set of values for all given ports.
#
# usage: getFields(self,ports,oids)
#        ports: Reference to a list of ports, in any allowable port format
#        oids: A list of OIDs to retrieve values for
#
# On sucess, returns a two-dimensional list indexed by port,oid
#
sub getFields($$$) {
	my $self = shift;
	my ($ports,$oids) = @_;

	my @ifindicies = $self->convertPortFormat($PORT_FORMAT_IFINDEX,@$ports);
	my @oids = @$oids;

	# Put together an SNMP::VarList for all the values we want to get
	my @vars = ();
	foreach my $ifindex (@ifindicies) {
		foreach my $oid (@oids) {
			push @vars, ["$oid","$ifindex"];
		}
	}

	# If we try to ask for too many things at once, we get back really bogus
	# errors. So, we limit ourselves to an arbitrary number that, by
	# experimentation, works.
	my $maxvars = 16;
	my @results = ();
	while (@vars) {
		my $varList = new SNMP::VarList(splice(@vars,0,$maxvars));
		my $rv = snmpitGetWarn($self->{SESS},$varList);
		push @results, @$varList;
	}
	    
	# Build up the two-dimensional list for returning
	my @return = ();
	foreach my $i (0 .. $#ifindicies) {
		foreach my $j (0 .. $#oids) {
			my $val = shift @results;
			$return[$i][$j] = $$val[2];
		}
	}

	return @return;
}

##############################################################################
## Trunk and port channel backends - not fully implemented yet.
##

#
# Set a port's mode to "trunking"
#
# usage: enablePortTrunking2($self, $port, $vlan_number, $equaltrunking)
#        modport: module.port of the trunk to operate on
#        nativevlan: VLAN number of the native VLAN for this trunk
#        equalmode: don't do dual mode; tag PVID also.
#
# returns: 1 on success, 0 otherwise
#
sub enablePortTrunking2($$$$) {
    my ($self, $port, $native_vlan, $equalmode) = @_;
    my $id = "$self->{NAME}::enablePortTrunking2()";

    my ($pifindex) = $self->convertPortFormat($PORT_FORMAT_IFINDEX, $port);
    if (!$pifindex) {
	warn "$id: ERROR: Unknown port: $port\n";
	return 0;
    }
    
    my $native_ifindex = $self->getVlanIfindex($native_vlan);
    if (!$native_ifindex) {
	warn "$id: ERROR: Unknown vlan: $native_vlan\n";
	return 0;
    }

    # Remove the port from any vlans it might be in.
    my $tagged_only = 0;
    if ($self->removePortsFromAllVlans($tagged_only, $port)) {
	warn "$id: ERROR: Failed to remove $port from existing vlan(s)!";
	return 0;
    }

    # Add the port to the native vlan; tagged if equal trunking mode
    # was requested, and untagged if not. Refuse to do this if the
    # requested vlan is vlan 1.
    if ($native_vlan != 1) {
	# Next, add it as tagged if 'dual' mode, untagged if 'equal' mode.
	my $portmask = $self->convertIfindexesToBitmask([$pifindex]);
	my $allzeromask = pack("B*", "00000000" x length($portmask));
	my $ubitmask = $equalmode ? $allzeromask : $portmask;
	if ($self->setPortMembership("on", $portmask, $ubitmask, 
				     $native_ifindex) != 0) {
	    warn "$id: ERROR: Could not add port $port to vlan ".
		"$native_vlan.\n";
	    return 0;
	}
    }

    # Add to the global list of trunk ports just in case the trunking
    # state doesn't get updated in the DB before other calls are made
    # that depend on it.
    $self->{TRUNKS}->{$pifindex} = 1;

    return 1;
}

#
# Disable trunking mode for a port
#
# usage: disablePortTrunking($self, $modport)
#        $self - reference to "this" object
#        $port - port to remove (any supported port format)
#
# returns: 1 on success, 0 on failure.
#
sub disablePortTrunking($$) {
    my ($self, $port) = @_;
    my $id = "$self->{NAME}::disablePortTrunking()";
    
    my ($pifindex) = $self->convertPortFormat($PORT_FORMAT_IFINDEX, $port);
    if (!$pifindex) {
	warn "$id: ERROR: Unknown port: $port\n";
	return 0;
    }

    # Remove the port from any VLAN it might be in, except for the
    # native (untagged) vlan.  We do this as a precaution - upper
    # layers should have cleaned up already.
    my $tagged_only = 1;
    if ($self->removePortsFromAllVlans($tagged_only, $port)) {
	warn "$id: ERROR: Could not remove $port from any/all vlans!";
	return 0;
    }

    # Remove from global trunk port list.
    delete($self->{TRUNKS}->{$pifindex})
	if exists($self->{TRUNKS}->{$pifindex});

    return 1;
}


#
# Get the ifindex for an EtherChannel (trunk given as a list of ports)
#
# usage: getChannelIfIndex(self, ports)
#        Returns: undef if more than one port is given, and no channel is found
#           an ifindex if a channel is found and/or only one port is given.
#
sub getChannelIfIndex($@) {
    my $self = shift;
    my @ports = @_;
    my @modports = $self->convertPortFormat($PORT_FORMAT_MODPORT,@ports);
    my $ifindex = undef;
    my $id = "$self->{NAME}::getChannelIfIndex()";

    $self->debug("$id: entering ".join(",",@ports)."\n");

    return undef
        if (! @modports);

    $self->debug("$id: ".join(",",@modports)."\n");

    my ($rows) = snmpitBulkwalkWarn($self->{SESS},[$OID_AGGPLIST]);

    # Try to find the input ports in the membership lists of the port
    # channels on this switch. Stop and return the first match found.
    if ($rows) {
        RESULTS: foreach my $result (@{$rows}) {
	    my ($oid,$channelid,$members) = @{$result};
	    $self->debug("$id: got $oid, $channelid, members $members\n",2);
	    # Apparently the iid (channelid) is not filled in when
	    # walking this OID tree.  Check for a null iid, and substitute
	    # the last component of the returned OID if necessary.
	    if (!$channelid) {
		$channelid = substr($oid, rindex($oid,'.') + 1);
	    }
	    # Chop up membership list into individual members.  The stupid
	    # thing is returned as a string that looks like this:
	    # "Fo 0/52 Fo 0/56 ...". So, we must hop over the port type
	    # identifiers, and grab the port numbers.
	    my @elements = split(/\s+/, $members);
	    for (my $i = 0; $i < @elements; $i += 2) {
		my $membmodport = join(".", split(/\//, $elements[$i+1]));
		foreach my $modport (@modports) {
		    if ($modport eq $membmodport && 
			exists($self->{POIFINDEX}{"Po$channelid"})) {
			$ifindex = $self->{POIFINDEX}{"Po$channelid"};
			last RESULTS;
		    }
		}
	    }
        }
    }

    # If we don't yet have a portchannel index, and a single port was
    # passed in, just return the ifindex for that port (single wire trunks).
    if (!$ifindex && scalar(@ports) == 1) {
	if (exists($self->{IFINDEX}{$ports[0]})) {
	    $ifindex = $self->{IFINDEX}{$ports[0]};
	}
    }

    $self->debug("$id: $ifindex\n");
    return $ifindex;
}

#
# Helper function that calls the Expect CLI wrapper for this switch to
# add/remove a portchannel to/from a vlan.  That this task cannot be
# carried out via a programmatic API (snmp or other) is terrible.
#
sub setChannelVlan($$$;$) {
    my ($self, $vlanid, $poifindex, $remove) = @_;
    $remove ||= 0;
    my $id = "$self->{NAME}::setChannelVlan";

    if (!exists($self->{POIFINDEX}{$poifindex})) {
	warn "$id: $poifindex does not exist in portchannel ifindex map!\n";
	return 1;
    }

    my $poname = $self->{POIFINDEX}{$poifindex};
    my $cmd = $remove ? "no tagged $poname" : "tagged $poname";
    my $isconfig = 1;
    my $vlifname = "vlan$vlanid";
    my ($res, $out) = $self->{EXP_OBJ}->doCLICmd($cmd, $isconfig, $vlifname);
    if ($res) {
	warn "$id: Error adding vlan to channel: $out\n";
    }
    return $res;
}

#
# Enable, or disable,  port on a trunk
#
# usage: setVlansOnTrunk(self, modport, value, vlan_numbers)
#        modport: module.port of the trunk to operate on
#        value: 0 to disallow the VLAN on the trunk, 1 to allow it
#        vlan_numbers: An array of 802.1Q VLAN numbers to operate on
#        Returns 1 on success, 0 otherwise
#
sub setVlansOnTrunk($$$$) {
    my ($self, $modport, $value, @vlan_numbers) = @_;
    my $errors = 0;
    my $id = $self->{NAME} . "::setVlansOnTrunk";

    $self->debug("$id: entering, modport: $modport, value: $value, vlans: ".join(",",@vlan_numbers)."\n");

    my ($ifindex) = $self->convertPortFormat($PORT_FORMAT_IFINDEX, $modport);
    if (!$ifindex) {
	warn "$id: WARNING: Could not get ifindex for port $modport\n";
	return 0;
    }

    #
    # Some error checking (from HP)
    #
    if (($value != 1) && ($value != 0)) {
	warn "$id: WARNING: Invalid value $value passed to function.\n";
	return 0;
    }
    if (grep(/^1$/,@vlan_numbers)) {
	warn "$id: WARNING: VLAN 1 passed to function.\n";
	return 0;
    }

    # Add or remove the vlan from the trunk on the port or portchannel.
    # Different code is called to manipulate the trunk depending on whether
    # the interface is a regular port or a port channel.
    foreach my $vlan (@vlan_numbers) {
	if ($value == 1) {
	    if (exists($self->{POIFINDEX}{$ifindex})) {
		$errors += $self->setChannelVlan($vlan, $ifindex);
	    } else {
		$errors += $self->setPortVlan($vlan, $ifindex);
	    }
	} else {
	    if (exists($self->{POIFINDEX}{$ifindex})) {
		my $remove = 1;
		$errors += $self->setChannelVlan($vlan, $ifindex, $remove);
	    } else {
		$errors += $self->removeSomePortsFromVlan($vlan, $ifindex);
	    }
	}
    }

    return $errors ? 0 : 1;
}

#
# Used to flush FDB entries easily
#
# usage: resetVlanIfOnTrunk(self, modport, vlan)
#
sub resetVlanIfOnTrunk($$$) {
    my ($self, $modport, $vlan) = @_;
    my $id = $self->{NAME} . "::resetVlansOnTrunk";

    $self->debug("$id: entering, modport: $modport, vlan: $vlan\n");

    $self->setVlansOnTrunk($modport, 0, $vlan);
    $self->setVlansOnTrunk($modport, 1, $vlan);

    return 0;
}


##############################################################################
## OpenFlow functionality - not implemented yet.
##

#
# Enable Openflow
#
sub enableOpenflow($$) {
    my $self = shift;
    my $vlan = shift;
    my $RetVal;
    
    #
    # Force10 switch doesn't support Openflow yet.
    #
    warn "ERROR: Force10 swith doesn't support Openflow now";
    return 0;
}

#
# Disable Openflow
#
sub disableOpenflow($$) {
    my $self = shift;
    my $vlan = shift;
    my $RetVal;
    
    #
    # Force10 switch doesn't support Openflow yet.
    #
    warn "ERROR: Force10 swith doesn't support Openflow now";
    return 0;
}

#
# Set controller
#
sub setOpenflowController($$$) {
    my $self = shift;
    my $vlan = shift;
    my $controller = shift;
    my $RetVal;
    
    #
    # Force10 switch doesn't support Openflow yet.
    #
    warn "ERROR: Force10 swith doesn't support Openflow now";
    return 0;
}

#
# Set listener
#
sub setOpenflowListener($$$) {
    my $self = shift;
    my $vlan = shift;
    my $listener = shift;
    my $RetVal;
    
    #
    # Force10 switch doesn't support Openflow yet.
    #
    warn "ERROR: Force10 swith doesn't support Openflow now";
    return 0;
}

#
# Get used listener ports
#
sub getUsedOpenflowListenerPorts($) {
    my $self = shift;
    my %ports = ();

    warn "ERROR: Force10 swith doesn't support Openflow now\n";

    return %ports;
}

#
# Check if Openflow is supported on this switch
#
sub isOpenflowSupported($) {
    #
    # Force10 switch doesn't support Openflow yet.
    #
    return 0;
}


# end with 1;
1;
