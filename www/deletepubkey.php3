<?php
#
# Copyright (c) 2000-2012 University of Utah and the Flux Group.
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
include("defs.php3");

#
# No PAGEHEADER since we spit out a redirect later.
# 

#
# Only known and logged in users can do this.
#
$this_user = CheckLoginOrDie(CHECKLOGIN_USERSTATUS|CHECKLOGIN_WEBONLY);
$uid       = $this_user->uid();
$isadmin   = ISADMIN();

#
# Verify page arguments.
#
$reqargs = RequiredPageArguments("target_user", PAGEARG_USER,
				 "key",         PAGEARG_INTEGER);
$optargs = OptionalPageArguments("canceled",    PAGEARG_BOOLEAN,
				 "confirmed",   PAGEARG_BOOLEAN);

# Need these below.
$target_dbid = $target_user->dbid();
$target_uid  = $target_user->uid();

#
# Verify that this uid is a member of one of the projects that the
# user is in. Must have proper permission in that group too. 
#
if (!$isadmin && 
    !$target_user->AccessCheck($this_user, $TB_USERINFO_MODIFYINFO)) {
    USERERROR("You do not have permission!", 1);
}

#
# Get the actual key.
#
$query_result =& $target_user->TableLookUp("user_pubkeys", "*", "idx='$key'");

if (! mysql_num_rows($query_result)) {
    USERERROR("Public Key for user '$target_uid' does not exist!", 1);
}

$row      = mysql_fetch_array($query_result);
$pubkey   = $row['pubkey'];
$chunky   = chunk_split($pubkey, 70, "<br>\n");
$internal = $row['internal'];
$nodelete = $row['nodelete'];

#
# Internal keys cannot be deleted without admin.
#
if (($internal || $nodelete) && !$isadmin) {
    USERERROR("You are not allowed to delete your system keys!", 1);
}

#
# We run this twice. The first time we are checking for a confirmation
# by putting up a form. The next time through the confirmation will be
# set. Or, the user can hit the cancel button, in which case we should
# probably redirect the browser back up a level.
#
if (isset($canceled) && $canceled) {
    PAGEHEADER("SSH Public Key Maintenance");
    
    echo "<center><h2><br>
          SSH Public Key deletion canceled!
          </h2></center>\n";

    $url = CreateURL("showpubkeys", $target_user);

    echo "<br>
          Back to <a href='$url'>ssh public keys</a> for user '$uid'.\n";
    
    PAGEFOOTER();
    return;
}

if (!isset($confirmed)) {
    PAGEHEADER("SSH Public Key Maintenance");

    echo "<center><h3><br>
          Are you <b>REALLY</b>
          sure you want to delete this SSH Public Key for user '$target_uid'?
          </h3>\n";

    $url = CreateURL("deletepubkey", $target_user, "key", $key);
    
    echo "<form action='$url' method=post>";
    echo "<b><input type=submit name=confirmed value=Confirm></b>\n";
    echo "<b><input type=submit name=canceled value=Cancel></b>\n";
    echo "</form>\n";
    echo "</center>\n";

    echo "<table align=center border=1 cellpadding=2 cellspacing=2>
           <tr>
              <td>$chunky</td>
           </tr>
          </table>\n";

    if ($internal || $nodelete) {
	echo "<center><font color=red size=+1>";
	echo "This is an internal key!</font><center>";
    }
    
    PAGEFOOTER();
    return;
}

#
# Audit
#
$uid_name  = $this_user->name();
$uid_email = $this_user->email();

$targuid_name  = $target_user->name();
$targuid_email = $target_user->email();

TBMAIL("$targuid_name <$targuid_email>",
     "SSH Public Key for '$target_uid' Deleted",
     "\n".
     "SSH Public Key for '$target_uid' deleted by '$uid'.\n".
     "\n".
     "$chunky\n".
     "\n".
     "Thanks,\n".
     "Testbed Operations\n",
     "From: $uid_name <$uid_email>\n".
     "Bcc: $TBMAIL_AUDIT\n".
     "Errors-To: $TBMAIL_WWW");

DBQueryFatal("delete from user_pubkeys ".
	     "where uid_idx='$target_dbid' and idx='$key'");

#
# update authkeys files and nodes, but only if user has a real account.
# The -w option can only be used on real users, and deleting a key does
# not require anything by the outside script if not a real user; it
# will complain and die!
#
if (HASREALACCOUNT($target_uid)) {
    ADDPUBKEY("-w $target_uid");
}

header("Location: " . CreateURL("showpubkeys", $target_user));

?>
