#!/usr/bin/perl
#
# Copyright (c) 2009 University of Utah and the Flux Group.
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
use SemiModern::Perl;
use TestBed::TestSuite;
use Test::More;

my $ns = <<'NSEND';
source tb_compat.tcl

set ns [new Simulator]

set node1 [$ns node]
set node2 [$ns node]

set lan1 [$ns make-lan "$node1 $node2" 5Mb 20ms]

set link1 [$ns duplex-link $node1 $node2 100Mb 50ms DropTail]

$ns run
NSEND
  
my $test = sub { 
  my ($e) = @_; 
  my $eid = $e->eid;
  ok($e->linktest, "$eid linktest"); 

  ok($e->link("link1")->down, "link down");
  sleep(2);

  my $n1ssh = $e->node("node1")->ssh;
  ok($n1ssh->cmdfailuredump("ping -c 5 10.1.2.3"));

  ok($e->link("link1")->up, "link up");
  sleep(2);
  ok($n1ssh->cmdsuccessdump("ping -c 5 10.1.2.3"));
};

rege(e('tplinkupdown'), $ns, $test, 5, 'single_node_tests');
