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
package TestBed::XMLRPC::Client::OSID;
use SemiModern::Perl;
use Moose;
use Data::Dumper;

extends 'TestBed::XMLRPC::Client';

#autoloaded/autogenerated/method_missings/etc getlist

=head1 NAME

TestBed::XMLRPC::Client::OSID

=over 4

=item C<getlist>

returns a list of available OS images 

=item C<info($image_name)>

returns the detailed info for image $image_name

=back

=cut

sub info { shift->augment( 'osid' => shift, @_ ); }

1;