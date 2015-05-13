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
# Verify page arguments.
#
$reqargs = RequiredPageArguments("uuid",  PAGEARG_STRING);

#
# Get current user.
#
RedirectSecure();
$this_user = CheckLoginOrRedirect();

SPITHEADER(1);

$profile = Profile::Lookup($uuid);
if (!$profile) {
    SPITUSERERROR("No such profile!");
}
else if ($this_user->uid_idx() != $profile->creator_idx() && !ISADMIN()) {
    SPITUSERERROR("Not enough permission!");
}
$profileid = $profile->profileid();
$profiles  = array();

$query_result =
    DBQueryFatal("select v.*,DATE(v.created) as created ".
		 "  from apt_profile_versions as v ".
		 "where v.profileid='$profileid' ".
		 "order by v.created desc");

while ($row = mysql_fetch_array($query_result)) {
    $idx     = $row["profileid"];
    $uuid    = $row["uuid"];
    $version = $row["version"];
    $pversion= $row["parent_version"];
    $name    = $row["name"];
    $pid     = $row["pid"];
    $created = $row["created"];
    $published = $row["published"];
    $creator = $row["creator"];
    $rspec   = $row["rspec"];
    $desc    = '';

    if ($version == 0) {
	$pversion = " ";
    }
    if (!$published) {
	$published = " ";
    }
    $parsed_xml = simplexml_load_string($rspec);
    if ($parsed_xml &&
	$parsed_xml->rspec_tour && $parsed_xml->rspec_tour->description) {
	$desc = (string) $parsed_xml->rspec_tour->description;
    }

    $profile = array();
    $profile["uuid"]    = $uuid;
    $profile["version"] = $version;
    $profile["creator"] = $creator;
    $profile["description"] = $desc;
    $profile["created"]     = $created;
    $profile["published"]   = $published;
    $profile["parent_version"] = $pversion;

    $profiles[] = $profile;
}

# Place to hang the toplevel template.
echo "<div id='history-body'></div>\n";

echo "<script type='text/javascript'>\n";
echo "    window.AJAXURL  = 'server-ajax.php';\n";
echo "</script>\n";
echo "<script type='text/plain' id='profiles-json'>\n";
echo json_encode($profiles);
echo "</script>\n";
echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
echo "<script src='js/lib/bootstrap.js'></script>\n";
echo "<script src='js/lib/require.js' data-main='js/profile-history'></script>\n";

SPITFOOTER();
?>
