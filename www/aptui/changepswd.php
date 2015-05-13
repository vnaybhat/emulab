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
$page_title = "Change Password";

RedirectSecure();

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("user",      PAGEARG_USER,
				 "key",       PAGEARG_STRING,
				 "password1", PAGEARG_STRING,
				 "password2", PAGEARG_STRING,
				 "reset",     PAGEARG_STRING);


#
# We use this page for both resetting a forgotten password, and for
# a logged in user to change their password. We use the "key" argument
# to tell us its a reset.
#
if (isset($key)) {
    if (!isset($user)) {
	SPITUSERERROR("Missing user argument");
	return;
    }
    # Half the key in the URL.
    $keyB = $key;
    # We also need the other half of the key from the browser.
    $keyA = (isset($_COOKIE[$TBAUTHCOOKIE]) ? $_COOKIE[$TBAUTHCOOKIE] : "");

    # If the browser part is missing, direct user to answer
    if ((isset($keyB) && $keyB != "") && (!isset($keyA) || $keyA == "")) {
	SPITUSERERROR("Oops, not able to proceed!<br>".
		      "Please read this ".
		      "<a href='$WIKIDOCURL/kb69'>Knowledge Base Entry</a> ".
		      "to see what the likely cause is.", 1);
	return;
    }
    if (!isset($keyA) || $keyA == "" || !preg_match("/^[\w]+$/", $keyA) ||
	!isset($keyB) || $keyB == "" || !preg_match("/^[\w]+$/", $keyB)) {
	SPITUSERERROR("Invalid keys in request");
	return;
    }
    # The complete key.
    $key = $keyA . $keyB;

    if (!$user->chpasswd_key() || !$user->chpasswd_expires()) {
	SPITUSERERROR("Why are you here?");
	return;
    }
    if ($user->chpasswd_key() != $key) {
	SPITUSERERROR("Invalid key in request.");
	return;
    }
    if (time() > $user->chpasswd_expires()) {
	SPITUSERERROR("Your key has expired. Please request a
               <a href='forgotpswd.php'>new key</a>.");
	return;
    }
}
else {
    #
    # The user must be logged in.
    #
    $this_user = CheckLoginOrRedirect();

    # Check for admin setting another users password.
    if (!isset($user)) {
	$user = $this_user;
    }
    elseif (!$this_user->SameUser($user) && !ISADMIN()) {
	SPITUSERERROR("Not enough permission to reset password for user");
	return;
    }
}

function SPITFORM($password1, $password2, $errors)
{
    global $keyB, $user;
    $user_uid = $user->uid();
	
    # XSS prevention.
    $password1 = CleanString($password1);
    $password2 = CleanString($password2);
    # XSS prevention.
    if ($errors) {
	while (list ($key, $val) = each ($errors)) {
	    # Skip internal error, we want the html in those errors
	    # and we know it is safe.
	    if ($key == "error") {
		continue;
	    }
	    $errors[$key] = CleanString($val);
	}
    }

    $formatter = function($field, $html) use ($errors) {
	$class = "form-group";
	if ($errors && array_key_exists($field, $errors)) {
	    $class .= " has-error";
	}
	echo "<div class='$class'>\n";
	echo "     $html\n";
	if ($errors && array_key_exists($field, $errors)) {
	    echo "<label class='control-label' for='inputError'>" .
		$errors[$field] . "</label>\n";
	}
	echo "</div>\n";
    };

    SPITHEADER(1);
    SPITNULLREQUIRE();
    
    echo "<div class='row'>
          <div class='col-lg-4  col-lg-offset-4
                      col-md-4  col-md-offset-4
                      col-sm-6  col-sm-offset-3
                      col-xs-10 col-xs-offset-1'>\n";

    echo "<form id='quickvm_form' role='form'
            method='post' action='changepswd.php?user=$user_uid'>\n";
    echo "<div class='panel panel-default'>
            <div class='panel-heading'>
              <h3 class='panel-title'>
                <center>Change Your Password</center></h3>
	    </div>
	    <div class='panel-body'>\n";

    $formatter("password1", 
	       "<input name='password1'
		       value='$password1'
                       class='form-control'
                       placeholder='Your new password'
                       autofocus type='password'>");
   
    $formatter("password2", 
	       "<input name='password2'
                       type='password'
                       value='$password2'
                       class='form-control'
                       placeholder='Confirm password'>");

    echo "<center>
           <button class='btn btn-primary'
              type='submit' name='reset'>Reset Password</button><center>\n";

    if (isset($keyB)) {
	echo "<input type='hidden' name='key' value='$keyB'>\n";
    }

    echo "  </div>\n";
    echo "</div>\n";
    echo "</form>\n";
    echo "</div>\n";
    echo "</div>\n";
    SPITFOOTER();
}

#
# If not clicked, then put up a form.
#
if (! isset($reset)) {
    SPITFORM("", "", null);
    return;
}
$errors = array();

#
# Reset clicked. Verify a proper password. 
#
if (!isset($password1) || $password1 == "") {
    $errors["password1"] = "Missing Field";
}
if (!isset($password2) || $password2 == "") {
    $errors["password2"] = "Missing Field";
}
if (!count($errors) && $password1 != $password2) {
    $errors["password2"] = "Passwords do not match";
}
if (!count($errors) &&
    ! CHECKPASSWORD($user->uid(),
		    $password1, $user->name(), $user->email(), $checkerror)) {
    $errors["password1"] = $checkerror;
}
if (count($errors)) {
    SPITFORM($password1, $password2, $errors);
    return;
}
$encoding = crypt("$password1");
$safe_encoding = escapeshellarg($encoding);

#
# Clear this for forgotten password.
#
if (isset($key)) {
    setcookie($TBAUTHCOOKIE, "", 1, "/", $WWWHOST, $TBSECURECOOKIES);
}
# Header after cookie.
SPITHEADER(1);
SpitWaitModal("waitwait");
SPITREQUIRE("async");
echo "<script>ShowWaitModal('waitwait');</script>\n";
flush();

#
# Invoke backend to deal with this.
#
$target_uid = $user->uid();

if (!HASREALACCOUNT($target_uid)) {
    $retval = SUEXEC("nobody", "nobody",
		     "webtbacct passwd $target_uid $safe_encoding",
		     SUEXEC_ACTION_CONTINUE);
}
else {
    $retval = SUEXEC($target_uid, "nobody",
		     "webtbacct passwd $target_uid $safe_encoding",
		     SUEXEC_ACTION_CONTINUE);
}
echo "<script>HideWaitModal('waitwait');</script>\n";
flush();

if ($retval) {
    SPITUSERERROR("Oops, error changing password");
}
else {
    echo "Your password has been changed.\n";
}

SPITFOOTER();
?>
