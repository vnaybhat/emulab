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
include_once("osinfo_defs.php");
include_once("geni_defs.php");
include_once("webtask.php");
chdir("apt");
include("quickvm_sup.php");
include("profile_defs.php");
include("instance_defs.php");
$page_title = "Experiment Status";
$ajax_request = 0;

#
# Get current user.
#
$this_user = CheckLogin($check_status);

#
# Verify page arguments.
#
$reqargs = OptionalPageArguments("uuid",    PAGEARG_STRING,
				 "extend",  PAGEARG_INTEGER,
				 "oneonly", PAGEARG_BOOLEAN);

if (!isset($uuid)) {
    SPITHEADER(1);
    echo "<div class='align-center'>
            <p class='lead text-center'>
              What experiment would you like to look at?
            </p>
          </div>\n";
    SPITFOOTER();
    return;
}

#
# See if the instance exists. If not, redirect back to the create page
#
$instance = Instance::Lookup($uuid);
if (!$instance) {
    SPITHEADER(1);
    echo "<div class='align-center'>
            <p class='lead text-center'>
              Experiment does not exist. Redirecting to the front page.
            </p>
          </div>\n";
    SPITFOOTER();
    flush();
    sleep(3);
    PAGEREPLACE("instantiate.php");
    return;
}
$creator = GeniUser::Lookup("sa", $instance->creator_uuid());
if (! $creator) {
    $creator = User::LookupByUUID($instance->creator_uuid());
}
if (!$creator) {
    SPITHEADER(1);
    echo "<div class='align-center'>
            <p class='lead text-center'>
               Hmm, there seems to be a problem.
            </p>
          </div>\n";
    SPITFOOTER();
    TBERROR("No creator for instance: $uuid", 0);
    return;
}
#
# Only logged in admins can access an experiment created by someone else.
#
if (! (isset($this_user) && ISADMIN())) {
    # An experiment created by a real user, can be accessed by that user only.
    # Ditto a guest user; must be the same guest.
    if (! ((get_class($creator) == "User" &&
	    isset($this_user) && $creator->uuid() == $this_user->uuid()) ||
	   (get_class($creator) == "GeniUser" &&
	    isset($_COOKIE['quickvm_user']) &&
	    $_COOKIE['quickvm_user'] == $creator->uuid()))) {
	PAGEERROR("You do not have permission to look at this experiment!");
    }
}
$slice = GeniSlice::Lookup("sa", $instance->slice_uuid());

$instance_status = $instance->status();
$creator_uid     = $creator->uid();
$creator_email   = $creator->email();
$profile         = Profile::Lookup($instance->profile_id(),
				   $instance->profile_version());
$profile_name    = $profile->name();
if ($slice) {
    $slice_urn       = $slice->urn();
    $slice_expires   = DateStringGMT($slice->expires());
    $slice_expires_text = gmdate("m-d\TH:i\Z", strtotime($slice->expires()));
}
else {
    $slice_urn = "";
    $slice_expires = "";
    $slice_expires_text = ""; 
}
$registered      = (isset($this_user) ? "true" : "false");
$profile_public  = ($profile->ispublic() ? "true" : "false");
$cansnap         = ((isset($this_user) &&
		     $this_user->idx() == $creator->idx() &&
		     $this_user->idx() == $profile->creator_idx()) ||
		    ISADMIN() ? 1 : 0);
$canclone        = (($profile->published() && isset($this_user) &&
		     $this_user->idx() == $creator->idx()) ||
		    ISADMIN() ? 1 : 0);
$snapping        = 0;
$oneonly         = (isset($oneonly) && $oneonly ? 1 : 0);
$isadmin         = (ISADMIN() ? 1 : 0);

#
# We give ssh to the creator (real user or guest user).
#
$dossh =
    (((isset($this_user) && $this_user->SameUser($creator)) ||
      (isset($_COOKIE['quickvm_user']) &&
       $_COOKIE['quickvm_user'] == $creator->uuid())) ? 1 : 0);

#
# See if we have a task running in the background for this instance.
# At the moment it can only be a snapshot task. If there is one, we
# have to tell the js code to show the status of the snapshot.
#
# XXX we could be imaging for a new profile (Cloning) instead. In that
# case the webtask object will not be attached to the instance, but to
# whatever profile is cloning. We do not know that profile here, so we
# cannot show that progress. Needs more thought.
#
if ($instance_status == "imaging") {
    $webtask = WebTask::LookupByObject($instance->uuid());
    if ($webtask && ! $webtask->exited()) {
	$snapping = 1;
    }
}

SPITHEADER(1);

# Place to hang the toplevel template.
echo "<div id='status-body'></div>\n";

echo "<script type='text/javascript'>\n";
echo "  window.APT_OPTIONS.uuid = '" . $uuid . "';\n";
echo "  window.APT_OPTIONS.instanceStatus = '" . $instance_status . "';\n";
echo "  window.APT_OPTIONS.profileName = '" . $profile_name . "';\n";
echo "  window.APT_OPTIONS.profilePublic = " . $profile_public . ";\n";
echo "  window.APT_OPTIONS.sliceURN = '" . $slice_urn . "';\n";
echo "  window.APT_OPTIONS.sliceExpires = '" . $slice_expires . "';\n";
echo "  window.APT_OPTIONS.sliceExpiresText = '" . $slice_expires_text . "';\n";
echo "  window.APT_OPTIONS.creatorUid = '" . $creator_uid . "';\n";
echo "  window.APT_OPTIONS.creatorEmail = '" . $creator_email . "';\n";
echo "  window.APT_OPTIONS.registered = $registered;\n";
echo "  window.APT_OPTIONS.isadmin = $isadmin;\n";
echo "  window.APT_OPTIONS.cansnap = $cansnap;\n";
echo "  window.APT_OPTIONS.canclone = $canclone;\n";
echo "  window.APT_OPTIONS.snapping = $snapping;\n";
echo "  window.APT_OPTIONS.oneonly = $oneonly;\n";
echo "  window.APT_OPTIONS.dossh = $dossh;\n";
echo "  window.APT_OPTIONS.AJAXURL = 'server-ajax.php';\n";
if (isset($extend) && $extend != "") {
    echo "  window.APT_OPTIONS.extend = $extend;\n";
}
echo "</script>\n";
echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
echo "<script src='js/lib/bootstrap.js'></script>\n";
echo "<script src='js/lib/require.js' data-main='js/status'></script>";
echo "<link rel='stylesheet'
            href='css/jquery-ui-1.10.4.custom.min.css'>\n";
# For progress bubbles in the imaging modal.
echo "<link rel='stylesheet' href='css/progress.css'>\n";

SPITFOOTER();
?>
