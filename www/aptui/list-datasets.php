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
include("blockstore_defs.php");
chdir("apt");
include("quickvm_sup.php");
$page_title = "My Datasets";

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
$target_idx = $target_user->uid_idx();
$target_uid = $target_user->uid();

SPITHEADER(1);

echo "<link rel='stylesheet'
            href='css/tablesorter.css'>\n";

$whereclause1 = "where l.owner_uid='$target_uid'";
$whereclause2 = "where d.creator_uid='$target_uid'";
$orderclause1 = "order by l.owner_uid";
$orderclause2 = "order by d.creator_uid";
$joinclause1  = "";
$joinclause2  = "";

if (isset($all)) {
    if (ISADMIN()) {
	$whereclause1 = "";
	$whereclause2 = "";
    }
    else {
	$joinclause1 =
	    "left join group_membership as g on ".
	    "     g.uid='$target_uid' and ".
	    "     g.pid=l.pid and g.pid_idx=g.gid_idx";
	$joinclause2 =
	    "left join group_membership as g on ".
	    "     g.uid='$target_uid' and ".
	    "     g.pid=d.pid and g.pid_idx=g.gid_idx";
	$whereclause1 =
	    "where l.owner_uid='$target_uid' or ".
	    "      g.uid_idx is not null ";
	$whereclause2 =
	    "where d.creator_uid='$target_uid' or ".
	    "      g.uid_idx is not null ";
    }
}

if ($embedded) {
    $query_result =
	DBQueryFatal("select l.* from project_leases as l ".
		     "$joinclause1 ".
		     "$whereclause1 $orderclause1");
}
else {
    $query_result =
	DBQueryFatal("select d.* from apt_datasets as d ".
		     "$joinclause2 ".
		     "$whereclause2 $orderclause2");
}

if (mysql_num_rows($query_result) == 0) {
    $message = "<b>No datasets to show you. Maybe you want to ".
	"<a id='embedded-anchors'
             href='create-dataset.php?embedded=$embedded'>
               create one?</a></b>
          <br><br>";

    if (ISADMIN() && $all == 0) {
	$message .= "<img src='images/redball.gif'>".
	    "<a id='embedded-anchors'
                href='list-datasets.php?all=1&embedded=$embedded'>
                 Show all datasets</a>";
    }
    echo $message;
    SPITREQUIRE("list-datasets");
    SPITFOOTER();
    exit();
}
echo "<div class='row'>
       <div class='col-lg-12 col-lg-offset-0
                   col-md-12 col-md-offset-0
                   col-sm-12 col-sm-offset-0
                   col-xs-12 col-xs-offset-0'>\n";

echo "<a id='embedded-anchors'
             href='create-dataset.php?embedded=$embedded'>
               Create a new dataset?</a>
          <br>";

echo "<input class='form-control search' type='search'
             id='dataset_search' placeholder='Search'>\n";

echo "  <table class='tablesorter'>
         <thead>
          <tr>
           <th>Name</th>
           <th>&nbsp</th>\n";
if (isset($all) && ISADMIN()) {
    echo " <th>Creator</th>";
}
echo "     <th>Project</th>
           <th>Created</th>
           <th>State</th>
          </tr>
         </thead>
         <tbody>\n";

while ($row = mysql_fetch_array($query_result)) {
    if ($embedded) {
	$uuid    = $row["uuid"];
	$idx     = $row["lease_idx"];
	$name    = $row["lease_id"];
	$pid     = $row["pid"];
	$creator = $row["owner_uid"];
	$created = $row["inception"];
	$state   = $row["state"];
    }
    else {
	$uuid    = $row["uuid"];
	$idx     = $row["idx"];
	$name    = $row["dataset_id"];
	$pid     = $row["pid"];
	$creator = $row["creator_uid"];
	$created = DateStringGMT($row["created"]);
	$state   = $row["state"];
    }

    echo " <tr>
            <td>$name</td>\n";

    echo " <td style='text-align:center'>
             <a class='btn btn-primary btn-xs' type='button'
	        id='show-dataset-button'
                href='show-dataset.php?uuid=$uuid&embedded=$embedded'>Show</a>
            </td>\n";

    if (isset($all) && ISADMIN()) {
	echo "<td>$creator</td>";
    }
    echo "  <td style='white-space:nowrap'>$pid</td>
            <td class='format-date'>$created</td>
            <td>$state</td>
           </tr>\n";
}
echo "   </tbody>
        </table>\n";

if (!isset($all)) {
    if (ISADMIN()) {
	echo "<img src='images/redball.gif'>
          <a id='embedded-anchors'
             href='list-datasets.php?all=1&embedded=$embedded'>
             Show all user datasets</a>\n";
    }
    else {
	echo "<img src='images/blueball.gif'>
          <a id='embedded-anchors'
             href='list-datasets.php?all=1&embedded=$embedded'>
             Show all datasets you can use</a>\n";
    }
}
echo"   </div>
      </div>\n";

echo "<script type='text/javascript'>\n";
echo "    window.AJAXURL  = 'server-ajax.php';\n";
echo "</script>\n";
SPITREQUIRE("list-datasets");
SPITFOOTER();
?>
