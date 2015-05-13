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
# Must be after quickvm_sup.php since it changes the auth domain.
include_once("../session.php");

#
# Poor man routing description.
#
$routing = array("myprofiles" =>
			array("file"    => "myprofiles.ajax",
			      "guest"   => false,
			      "methods" => array("GetProfile" =>
						      "Do_GetProfile")),
		 "geni-login" =>
			array("file"    => "geni-login.ajax",
			      "guest"   => true,
			      "methods" => array("GetSignerInfo" =>
						      "Do_GetSignerInfo",
						 "CreateSecret" =>
						      "Do_CreateSecret",
						 "VerifySpeaksfor" =>
						      "Do_VerifySpeaksfor")),
		 "instantiate" =>
			array("file"    => "instantiate.ajax",
			      "guest"   => true,
			      "methods" => array("GetProfile" =>
						     "Do_GetProfile")),
		 "manage_profile" =>
			array("file"    => "manage_profile.ajax",
			      "guest"   => false,
			      "methods" => array("CloneStatus" =>
						     "Do_CloneStatus",
						 "DeleteProfile" =>
						     "Do_DeleteProfile",
						 "PublishProfile" =>
						     "Do_PublishProfile",
						 "Instantiate" =>
						     "Do_Instantiate",
						 "InstantiateAsGuest" =>
						     "Do_GuestInstantiate",
						 "CheckScript" =>
						       "Do_CheckScript")),
		 "status" =>
			array("file"    => "status.ajax",
			      "guest"   => true,
			      "methods" => array("GetInstanceStatus" =>
						   "Do_GetInstanceStatus",
						 "TerminateInstance" =>
						    "Do_TerminateInstance",
						 "GetInstanceManifest" =>
						    "Do_GetInstanceManifest",
						 "GetSSHAuthObject" =>
						    "Do_GetSSHAuthObject",
						 "ConsoleURL" =>
						     "Do_ConsoleURL",
						 "RequestExtension" =>
						     "Do_RequestExtension",
						 "SnapShot" =>
						     "Do_Snapshot",
						 "SnapshotStatus" =>
						 "Do_SnapshotStatus")),
		 "approveuser" =>
			array("file"    => "approveuser.ajax",
			      "guest"   => false,
			      "methods" => array("approve" =>
						     "Do_Approve",
						 "deny" =>
						      "Do_Deny")),
		 "dataset" =>
			array("file"    => "dataset.ajax",
			      "guest"   => false,
			      "methods" => array("create" =>
						      "Do_CreateDataset",
						 "refresh" =>
						      "Do_RefreshDataset",
						 "delete" =>
						      "Do_DeleteDataset",
						 "approve" =>
						      "Do_ApproveDataset")),
    );

#
# Redefine this so we return XML instead of html for all errors.
#
$PAGEERROR_HANDLER = function($msg, $status_code = 0) {
    if ($status_code == 0) {
	$status_code = 1;
    }
    SPITAJAX_ERROR(1, $msg);
    return;
};

#
# Included file determines if guest user okay.
#
$this_user = CheckLogin($check_status);

#
# Check user login, called by included code. Basically just a
# way to let guest users pass through when allowed, without
# duplicating the code in each file.
#
function CheckLoginForAjax($guestokay = false)
{
    global $this_user, $check_status;

    # Known user, but timed out.
    if ($check_status & CHECKLOGIN_TIMEDOUT) {
	SPITAJAX_ERROR(2, "Your login has timed out");
	exit(2);
    }
    # Logged in user always okay.
    if (isset($this_user)) {
	if ($check_status & CHECKLOGIN_MAYBEVALID) {
	    SPITAJAX_ERROR(2, "Your login cannot be verified. Cookie problem?");
	    exit(2);
	}
	return;
    }
    if (!$guestokay) {
	SPITAJAX_ERROR(2, "Your are not logged in");	
	exit(2);
    }
}

#
# Verify page arguments.
#
$optargs = RequiredPageArguments("ajax_route",    PAGEARG_STRING,
				 "ajax_method",   PAGEARG_STRING,
				 "ajax_args",     PAGEARG_ARRAY);

#
# Verify page and method.
#
if (! array_key_exists($ajax_route, $routing)) {
    SPITAJAX_ERROR(1, "Invalid route: $ajax_route");
    exit(1);
}
if (! array_key_exists($ajax_method, $routing[$ajax_route]["methods"])) {
    SPITAJAX_ERROR(1, "Invalid method: $ajax_route,$ajax_method");
    exit(1);
}
CheckLoginForAjax($routing[$ajax_route]["guest"]);
include($routing[$ajax_route]["file"]);
call_user_func($routing[$ajax_route]["methods"][$ajax_method]);

?>
