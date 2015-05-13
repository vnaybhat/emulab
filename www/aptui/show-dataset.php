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
include("lease_defs.php");
chdir("apt");
include("quickvm_sup.php");
include("dataset_defs.php");
# Must be after quickvm_sup.php since it changes the auth domain.
$page_title = "Show Dataset";

#
# Get current user.
#
RedirectSecure();
$this_user = CheckLoginOrRedirect();
$this_idx  = $this_user->uid_idx();
$this_uid  = $this_user->uid();

#
# Verify page arguments.
#
$optargs = RequiredPageArguments("uuid", PAGEARG_UUID);

#
# Either a local lease or a remote dataset. 
#
$dataset = Lease::Lookup($uuid);
if (!$dataset) {
    $dataset = Dataset::Lookup($uuid);
}
if (!$dataset) {
    SPITUSERERROR("No such dataset!");
}
if (!$dataset->AccessCheck($this_user, $LEASE_ACCESS_READINFO)) {
    SPITUSERERROR("Not enough permission!");
}
# Owner or admin can delete.
$candelete  = (ISADMIN() || $dataset->owner_uid() == $this_uid ? 1 : 0);

# An admin can approve an unapproved lease.
$canapprove = ($embedded && ISADMIN() &&
	       $dataset->state() == "unapproved" ? 1 : 0);

# Remote datasets can be refreshed.
$canrefresh = ($dataset->islocal() ? 0 : 1);

$fields = array();
if ($dataset->type() == "stdataset") {
    $fields["dataset_type"] = "short term";
}
elseif ($dataset->type() == "ltdataset") {
    $fields["dataset_type"] = "long term";
}
else {
    $fields["dataset_type"] = $dataset->type();
}
$fields["dataset_creator"]  = $dataset->owner_uid();
$fields["dataset_pid"]      = $dataset->pid();
$fields["dataset_gid"]      = $dataset->gid();
$fields["dataset_name"]     = $dataset->id();
$fields["dataset_size"]     = $dataset->size();
$fields["dataset_fstype"]   = ($dataset->fstype() ?
			       $dataset->fstype() : "none");
$fields["dataset_created"]  = DateStringGMT($dataset->created());
$fields["dataset_expires"]  = ($dataset->expires() ?
			       DateStringGMT($dataset->expires()) : "");
$fields["dataset_lastused"] = ($dataset->last_used() ?
			       DateStringGMT($dataset->last_used()) : "");
$fields["dataset_uuid"]     = $uuid;
$fields["dataset_idx"]      = $dataset->idx();
$fields["dataset_urn"]      = $dataset->URN();

#
# The state is a bit of a problem, since local leases do not have
# an "allocating" state. For a remote dataset, we get set to busy.
# Need to unify this. But the main point is that we want to tell
# the user that the dataset is busy allocation.
#
if ($dataset->state() == "busy" ||
    ($dataset->state() == "unapproved" && $dataset->locked())) {
    $fields["dataset_state"] = "allocating";
}
else {
    $fields["dataset_state"] = $dataset->state();
}
SPITHEADER(1);

# Place to hang the toplevel template.
echo "<div id='main-body'></div>\n";

echo "<script type='text/plain' id='fields-json'>\n";
echo htmlentities(json_encode($fields)) . "\n";
echo "</script>\n";

SpitOopsModal("oops");
SpitWaitModal("waitwait");

echo "<script type='text/javascript'>\n";
echo "    window.TITLE      = '$page_title';\n";
echo "    window.UUID       = '$uuid';\n";
echo "    window.CANDELETE  = $candelete;\n";
echo "    window.CANAPPROVE = $canapprove;\n";
echo "    window.CANREFRESH = $canrefresh;\n";
echo "</script>\n";
SPITREQUIRE("show-dataset");
SPITFOOTER();

?>
