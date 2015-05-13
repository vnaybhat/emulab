<?php
#
# Copyright (c) 2007, 2010 University of Utah and the Flux Group.
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
require("defs.php3");

# These error codes must match whats in the client, but of course.
define("WASTATUS_OKAY"	,		0);
define("WASTATUS_MISSINGARGS",		100);
define("WASTATUS_INVALIDARGS",		101);
define("WASTATUS_BADPRIVKEY",		102);
define("WASTATUS_BADIPADDR",		103);
define("WASTATUS_BADREMOTEIP",		104);
define("WASTATUS_IPADDRINUSE",		105);
define("WASTATUS_MUSTUSESSL",		106);
define("WASTATUS_OTHER",		199);

#
# Spit back a text message we can display to the user on the console
# of the node running the checkin. We could return an http error, but
# that would be of no help to the user on the other side.
# 
function SPITSTATUS($status)
{
    header("Content-Type: text/plain");
    echo "emulab_status=$status\n";
}

# Required arguments
$reqargs = RequiredPageArguments("IP",         PAGEARG_STRING,
				 "privkey",    PAGEARG_STRING);
$optargs = OptionalPageArguments("hostname",   PAGEARG_STRING);

# Must use https,
if (!isset($_SERVER["SSL_PROTOCOL"])) {
    SPITSTATUS(WASTATUS_MUSTUSESSL);
    return;
}

if (!preg_match('/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/', $IP) ||
    !preg_match('/^[\w]+$/', $privkey) ||
    (isset($hostname) &&
     !preg_match('/^[-\w\.]+$/', $hostname))) {
    SPITSTATUS(WASTATUS_INVALIDARGS);
    return;
}

#
# Make sure this is a valid privkey before we invoke the backend.
#
$query_result =
    DBQueryFatal("select IP from widearea_nodeinfo where privkey='$privkey'");
if (! mysql_num_rows($query_result)) {
    SPITSTATUS(WASTATUS_BADPRIVKEY);
    return;
}

#
# Invoke the backend and return the status. We send the IP since cause we
# have to deal with nodes with dynamic IP addresses.
#
$retval = SUEXEC("nobody", $TBADMINGROUP,
		 "webwanodecheckin " .
		 (isset($hostname) ? "-h $hostname " : "") . "$privkey $IP", 
		 SUEXEC_ACTION_IGNORE);

if ($retval) {
    SUEXECERROR(SUEXEC_ACTION_CONTINUE);
}
SPITSTATUS($retval);

?>
