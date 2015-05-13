<?php
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
chdir("..");
include("defs.php3");
chdir("apt");
include("quickvm_sup.php");

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("ajax_request", PAGEARG_BOOLEAN);

#
# Get current user.
#
$this_user = CheckLogin($check_status);
if ($this_user) {
    if (DOLOGOUT($this_user) != 0) {
	if ($ajax_request) {
	    SPITAJAX_ERROR(1, "Logout failed");
	    exit();
	}
	else {
	    SPITHEADER();
	    echo "<center><font color=red>Logout failed!</font></failed>\n";
            echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
            echo "<script src='js/lib/bootstrap.js'></script>\n";
            echo "<script src='js/lib/require.js' data-main='js/main'></script>";
	    SPITFOOTER();
	}
    }
}
if ($ajax_request) {
    SPITAJAX_RESPONSE("");
    exit();
}
header("Location: instantiate.php");
?>
