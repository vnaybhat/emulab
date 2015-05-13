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
$page_title = "Create Dataset";

#
# Get current user.
#
RedirectSecure();
$this_user = CheckLoginOrRedirect();
$this_idx  = $this_user->uid_idx();

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("create",      PAGEARG_STRING,
				 "formfields",  PAGEARG_ARRAY);

#
# Spit the form
#
function SPITFORM($formfields, $errors)
{
    global $this_user, $projlist, $embedded;
    $button_label = "Create";
    $title        = "Create Dataset";

    SPITHEADER(1);

    # Place to hang the toplevel template.
    echo "<div id='main-body'></div>\n";

    # I think this will take care of XSS prevention?
    echo "<script type='text/plain' id='form-json'>\n";
    echo htmlentities(json_encode($formfields)) . "\n";
    echo "</script>\n";
    echo "<script type='text/plain' id='error-json'>\n";
    echo htmlentities(json_encode($errors));
    echo "</script>\n";

    #
    # Pass project list through. Need to convert to list without groups.
    # When editing, pass through a single value. The template treats a
    # a single value as a read-only field.
    #
    $plist = array();
    while (list($project) = each($projlist)) {
	$plist[] = $project;
    }
    echo "<script type='text/plain' id='projects-json'>\n";
    echo htmlentities(json_encode($plist));
    echo "</script>\n";
    
    # FS types.
    $fstypelist = array();
    $fstypelist["none"] = "none";
    $fstypelist["ext2"] = "ext2";
    $fstypelist["ext3"] = "ext3";
    $fstypelist["ext4"] = "ext4";
    $fstypelist["ufs"]  = "ufs";
    $fstypelist["ufs2"] = "ufs2";
    echo "<script type='text/plain' id='fstypes-json'>\n";
    echo htmlentities(json_encode($fstypelist));
    echo "</script>\n";

    echo "<link rel='stylesheet'
            href='css/jquery-ui.min.css'>\n";
    
    echo "<script type='text/javascript'>\n";
    echo "    window.AJAXURL  = 'server-ajax.php';\n";
    echo "    window.TITLE    = '$title';\n";
    echo "    window.BUTTONLABEL = '$button_label';\n";
    echo "</script>\n";

    SpitOopsModal("oops");
    SpitWaitModal("waitwait");
    
    SPITREQUIRE("create-dataset");
    SPITFOOTER();
}

#
# See what projects the user can do this in.
#
$projlist = $this_user->ProjectAccessList($TB_PROJECT_CREATEEXPT);

if (! isset($create)) {
    $errors   = array();
    $defaults = array();

    $defaults["dataset_type"]   = 'stdataset';
    $defaults["dataset_fstype"] = 'ext3';

    SPITFORM($defaults, $errors);
    return;
}
SPITFORM($formfields, array());

?>
