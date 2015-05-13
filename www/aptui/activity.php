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
include("profile_defs.php");
$page_title = "My Profiles";

#
# Get current user.
#
RedirectSecure();
$this_user = CheckLoginOrRedirect();
SPITHEADER(1);

if (!ISADMIN()) {
    SPITUSERERROR("Not enough permission to view this page!");
}
$instances = array();

#
# First existing instances and then the history table.
#
$query1_result =
    DBQueryFatal("select i.uuid,i.profile_version,i.created,'' as destroyed, ".
		 "   i.creator,p.uuid as profile_uuid,p.name,p.pid,u.email ".
		 "  from apt_instances as i ".
		 "left join apt_profile_versions as p on ".
		 "     p.profileid=i.profile_id and ".
		 "     p.version=i.profile_version ".
		 "left join geni.geni_users as u on u.uuid=i.creator_uuid ".
		 "order by i.created desc");
$query2_result =
    DBQueryFatal("select h.uuid,h.profile_version,h.created,h.destroyed, ".
		 "    h.creator,p.uuid as profile_uuid,p.name,p.pid,u.email ".
		 "  from apt_instance_history as h ".
		 "left join apt_profile_versions as p on ".
		 "     p.profileid=h.profile_id and ".
		 "     p.version=h.profile_version ".
		 "left join geni.geni_users as u on u.uuid=h.creator_uuid ".
		 "order by h.created desc");

if (mysql_num_rows($query1_result) == 0 &&
    mysql_num_rows($query2_result) == 0) {
    $message = "<b>Oops, there is no activity to show you.</b><br>";
    SPITUSERERROR($message);
    exit();
}

foreach (array($query1_result, $query2_result) as $query_result) {
    while ($row = mysql_fetch_array($query_result)) {
	$uuid      = $row["uuid"];
	$pname     = $row["name"];
	$pproj     = $row["pid"];
	$puuid     = $row["profile_uuid"];
	$pversion  = $row["profile_version"];
	$created   = $row["created"];
	$destroyed = $row["destroyed"];
	$creator   = $row["creator"];
	$email     = $row["email"];
	# If a guest user, use email instead.
	if (isset($email)) {
	    $creator = $email;
	}

	$instance = array();
	$instance["uuid"]        = $uuid;
	$instance["p_name"]      = $pname;
	$instance["p_pid"]       = $pproj;
	$instance["p_uuid"]      = $puuid;
	$instance["p_version"]   = $pversion;
	$instance["creator"]     = $creator;
	$instance["created"]     = $created;
	$instance["destroyed"]   = $destroyed;
	$instances[] = $instance;
    }
}

# Place to hang the toplevel template.
echo "<div id='activity-body'></div>\n";

echo "<script type='text/javascript'>\n";
echo "    window.AJAXURL  = 'server-ajax.php';\n";
echo "</script>\n";
echo "<script type='text/plain' id='instances-json'>\n";
echo json_encode($instances);
echo "</script>\n";
echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
echo "<script src='js/lib/bootstrap.js'></script>\n";
echo "<script src='js/lib/require.js' data-main='js/activity'></script>\n";

SPITFOOTER();
?>
