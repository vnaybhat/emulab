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
$page_title = "My Profiles";

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

SPITHEADER(1);

echo "<link rel='stylesheet'
            href='css/tablesorter.css'>\n";

$whereclause = "where v.creator_idx='$target_idx'";
$joinclause  = "";
$orderclause = "";

if (isset($all)) {
    if (ISADMIN()) {
	$whereclause = "";
    }
    else {
	$joinclause =
	    "left join group_membership as g on ".
	    "     g.uid_idx='$target_idx' and ".
	    "     g.pid_idx=v.pid_idx and g.pid_idx=g.gid_idx";
	$whereclause =
	    "where p.public=1 or p.shared=1 or v.creator_idx='$target_idx' or ".
	    "      g.uid_idx is not null ";
    }
}

$query_result =
    DBQueryFatal("select p.*,v.*,DATE(v.created) as created ".
		 "   from apt_profiles as p ".
		 "left join apt_profile_versions as v on ".
		 "     v.profileid=p.profileid and ".
		 "     v.version=p.version ".
		 "$joinclause ".
		 "$whereclause order by v.creator");

if (mysql_num_rows($query_result) == 0) {
    $message = "<b>No profiles to show you. Maybe you want to ".
	"<a href='manage_profile.php'>create one?</a></b><br><br>";

    if (ISADMIN()) {
	$message .= "<img src='images/redball.gif'>".
	    "<a href='myprofiles.php?all=1'>Show all user Profile</a>";
    }
    SPITUSERERROR($message);
    exit();
}
echo "<div class='row'>
       <div class='col-lg-12 col-lg-offset-0
                   col-md-12 col-md-offset-0
                   col-sm-12 col-sm-offset-0
                   col-xs-12 col-xs-offset-0'>\n";

echo "<input class='form-control search' type='search'
             id='profile_search' placeholder='Search'>\n";

echo "  <table class='tablesorter'>
         <thead>
          <tr>
           <th>Name</th>
           <th>&nbsp</th>
           <th>&nbsp</th>\n";
if (isset($all) && ISADMIN()) {
    echo " <th>Creator</th>";
}
echo "     <th>Project</th>
           <th>Description</th>
           <th>Created</th>
           <th>Listed</th>
           <th>Privacy</th>
          </tr>
         </thead>
         <tbody>\n";

while ($row = mysql_fetch_array($query_result)) {
    $idx     = $row["profileid"];
    $uuid    = $row["uuid"];
    $version = $row["version"];
    $name    = $row["name"];
    $pid     = $row["pid"];
    $desc    = $row["description"];
    $created = DateStringGMT($row["created"]);
    $public  = $row["public"];
    $listed  = ($row["listed"] ? "Yes" : "No");
    $shared  = $row["shared"];
    $creator = $row["creator"];
    $rspec   = $row["rspec"];

    if ($public)
	$privacy = "Public";
    elseif ($shared)
	$privacy = "Shared";
    else
	$privacy = "Private";

    $parsed_xml = simplexml_load_string($rspec);
    if ($parsed_xml &&
	$parsed_xml->rspec_tour && $parsed_xml->rspec_tour->description) {
	$desc = $parsed_xml->rspec_tour->description;
    }
    
    echo " <tr>
            <td>$name</td>\n";

    if ($creator == $this_user->uid() || ISADMIN()) {
	echo " <td style='text-align:center'>
             <a class='btn btn-primary btn-xs' type='button'
                href='manage_profile.php?action=edit&uuid=$uuid'>Edit</a>
            </td>\n";
    }
    else {
	echo " <td style='text-align:center'>
             <a class='btn btn-primary btn-xs' type='button'
                href='manage_profile.php?action=copy&uuid=$uuid'>Copy</a>
            </td>\n";
    }
    echo "<td style='text-align:center'>
             <button class='btn btn-primary btn-xs showtopo_modal_button'
                     data-profile=$uuid>Topo</button>
            </td>\n";
    
    if (isset($all) && ISADMIN()) {
	echo "<td>$creator</td>";
    }
    echo "  <td style='white-space:nowrap'>$pid</td>
            <td>$desc</td>
            <td class='format-date'>$created</td>
            <td>$listed</td>
            <td>$privacy</td>
           </tr>\n";
}
echo "   </tbody>
        </table>\n";

if (!isset($all)) {
    if (ISADMIN()) {
	echo "<img src='images/redball.gif'>
          <a href='myprofiles.php?all=1'>Show all user profiles</a>\n";
    }
    else {
	echo "<img src='images/blueball.gif'>
          <a href='myprofiles.php?all=1'>Show all profiles you can instantiate</a>\n";
    }
}
echo"   </div>
      </div>\n";

echo "<!-- This is the topology view modal -->
      <div id='quickvm_topomodal' class='modal fade'>
        <div class='modal-dialog' id='showtopo_dialog'>
          <div class='modal-content'>
            <div class='modal-header'>
              <button type='button' class='close' data-dismiss='modal'
                      aria-hidden='true'>
                      &times;</button>
                <h3>Topology Viewer</h3>
            </div>
            <div class='modal-body'>
              <!-- This topo diagram goes inside this div -->
              <div class='panel panel-default'
                         id='showtopo_container'>
                <div class='panel-body'>
                  <div id='showtopo_nopicker' class='jacks'></div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>\n";


echo "<script type='text/javascript'>\n";
echo "    window.AJAXURL  = 'server-ajax.php';\n";
echo "</script>\n";
echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
echo "<script src='js/lib/bootstrap.js'></script>\n";
echo "<script src='js/lib/require.js' data-main='js/myprofiles'></script>\n";

SPITFOOTER();
?>
