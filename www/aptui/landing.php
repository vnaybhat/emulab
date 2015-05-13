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
include_once("geni_defs.php");
chdir("apt");
include("quickvm_sup.php");
include("instance_defs.php");

#
# Get current user but make sure coming in on SSL.
#
RedirectSecure();
$this_user = CheckLogin($check_status);
if ($ISCLOUD) {
    if (! ($CHECKLOGIN_STATUS & CHECKLOGIN_LOGGEDIN)) {
	header("Location: login.php");
	return;
    }
}

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("asguest", PAGEARG_BOOLEAN,
				 "from",    PAGEARG_STRING);

#
# Redirect logged in user.
#
if ($this_user) {
    if (Instance::UserHasInstances($this_user)) {
	header("Location: $APTBASE/myexperiments.php");
    }
    else {
	header("Location: $APTBASE/instantiate.php");
    }
    return;
}

#
# APT users might be guests.
#
if ($ISAPT) {
    #
    # If user appears to have an account, go to login page.
    # Continue as guest on that page.
    #
    if (REMEMBERED_ID()) {
	if (isset($asguest) && $asguest) {
	    # User clicked on continue as guest. If we do not delete the
	    # cookie, then user will go through the same loop next time
            # they click the Home button, since that points here. So delete
	    # the UID cookie. Not sure I like this.
	    ClearRememberedID();
	}
	else {
	    header("Location: login.php?from=landing");
	    return;
	}
    }
}
#
# A guest user. Go directly to status page.
#
if (isset($_COOKIE['quickvm_user'])) {
    $geniuser = GeniUser::Lookup("sa", $_COOKIE['quickvm_user']);
    if ($geniuser) {
	#
        # Look for existing quickvm. Show that.
	#
	$instance = Instance::LookupByCreator($geniuser->uuid());
	if ($instance && $instance->status() != "terminating") {
	    header("Location: status.php?uuid=" . $instance->uuid());
	    return;
	}
    }
}
header("Location: $APTBASE/instantiate.php");
?>
