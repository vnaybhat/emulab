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
include("profile_defs.php");
include("instance_defs.php");
$page_title = "My Experiments";
$dblink = GetDBLink("sa");

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("target_user",   PAGEARG_USER,
				 "all",           PAGEARG_BOOLEAN);

#
# Get current user.
#
RedirectSecure();
$this_user = CheckLoginOrRedirect();

if (!isset($target_user)) {
    $target_user = $this_user;
}
if (!$this_user->SameUser($target_user)) {
    if (!ISADMIN()) {
	SPITUSERERROR("You do not have permission to view ".
		      "target user's profiles");
	exit();
    }
}
$target_idx  = $target_user->uid_idx();
$target_uuid = $target_user->uuid();

SPITHEADER(1);

echo "<link rel='stylesheet'
            href='css/tablesorter.css'>\n";

$query_result =
    DBQueryFatal("select * from apt_instances ".
		 (isset($all) && ISADMIN() ?
		  "order by creator" : "where creator_uuid='$target_uuid'"));

if (mysql_num_rows($query_result) == 0) {
    $message = "<b>No experiments to show you. Maybe you want to ".
	"<a href='instantiate.php'>start one?</a></b><br><br>";

    if (ISADMIN()) {
	$message .= "<img src='images/redball.gif'>".
	    "<a href='myexperiments.php?all=1'>Show all user Experiments</a>";
    }
    SPITUSERERROR($message);
    exit();
}
echo "<div class='row'>
       <div class='col-lg-6 col-lg-offset-3
                   col-md-6 col-md-offset-3
                   col-sm-6 col-sm-offset-3
                   col-xs-4 col-xs-offset-4'>\n";

echo "<input class='form-control search' type='search'
             id='experiment_search' placeholder='Search'>\n";

echo "  <table class='tablesorter'>
         <thead>
          <tr>
           <th>Profile</th>\n";
if (isset($all) && ISADMIN()) {
    echo " <th>Creator</th>";
}
echo "     <th>Status</th>
           <th>Created</th>
          </tr>
         </thead>
         <tbody>\n";

while ($row = mysql_fetch_array($query_result)) {
    $profile_id   = $row["profile_id"];
    $version      = $row["profile_version"];
    $uuid         = $row["uuid"];
    $status       = $row["status"];
    $created      = DateStringGMT($row["created"]);
    $creator_idx  = $row["creator_idx"];
    $profile_name = $profile_id;
    $creator_uid  = $row["creator"];

    $profile = Profile::Lookup($profile_id, $version);
    if ($profile) {
	$profile_name = $profile->name();
    }

    echo " <tr>
            <td>
             <a href='status.php?uuid=$uuid'>$profile_name</a>
            </td>";
    if (isset($all) && ISADMIN()) {
	echo "<td>$creator_uid</td>";
    }
    echo "  <td>$status</td>
            <td class='format-date'>$created</td>
           </tr>\n";
}
echo "   </tbody>
        </table>\n";

if (ISADMIN() && !isset($all)) {
    echo "<img src='images/redball.gif'>
          <a href='myexperiments.php?all=1'>Show all user Experiments</a>\n";
}
echo " </div>
      </div>\n";

echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
echo "<script src='js/lib/bootstrap.js'></script>\n";
echo "<script src='js/lib/require.js' data-main='js/myexperiments'></script>\n";

SPITFOOTER();
?>
