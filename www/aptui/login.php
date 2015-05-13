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
$page_title = "Login";

#
# Get current user in case we need an error message.
#
$this_user = CheckLogin($check_status);

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("login",       PAGEARG_STRING,
				 "uid",         PAGEARG_STRING,
				 "password",    PAGEARG_PASSWORD,
				 "refer",       PAGEARG_BOOLEAN,
				 "referrer",    PAGEARG_STRING,
				 "from",        PAGEARG_STRING,
				 "ajax_request",PAGEARG_BOOLEAN);
				 
# See if referrer page requested that it be passed along so that it can be
# redisplayed after login. Save the referrer for form below.
if (isset($refer) &&
    isset($_SERVER['HTTP_REFERER']) && $_SERVER['HTTP_REFERER'] != "") {
    $referrer = $_SERVER['HTTP_REFERER'];

    # In order to get the auth cookies, pages need to go through https. But,
    # the user may have visited the last page with http. If they did, send them
    # back through https
    $referrer = preg_replace("/^http:/i","https:",$referrer);
} else if (! isset($referrer)) {
    $referrer = null;
}

#
# We want to show guest login, when redirected from the landing page
# or from the instantiate page. APT only.
#
$showguestlogin = 0;
if ($ISAPT && isset($from) &&
    ($from == "landing" || $from == "instantiate")) {
    $showguestlogin = 1;
}

if (NOLOGINS()) {
    if ($ajax_request) {
	SPITAJAX_ERROR(1, "logins are temporarily disabled");
	exit();
    }
    SPITHEADER();
    SPITUSERERROR("Sorry, logins are temporarily disabled, ".
		  "please try again later.");
    echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
    echo "<script src='js/lib/bootstrap.js'></script>\n";
    echo "<script src='js/lib/require.js' data-main='js/main'></script>";
    SPITFOOTER();
    return;
}

#
# Spit out the form.
# 
function SPITFORM($uid, $referrer, $error)
{
    global $TBDB_UIDLEN, $TBBASE, $refer;
    global $ISAPT, $ISCLOUD, $showguestlogin;
    $pwlab = ($ISAPT ? "Aptlab.net" : "CloudLab.net") .
	" or Emulab.net Username";
    
    header("Last-Modified: " . gmdate("D, d M Y H:i:s") . " GMT");
    header("Expires: Mon, 26 Jul 1997 05:00:00 GMT");
    header("Cache-Control: no-cache, max-age=0, must-revalidate, no-store");
    header("Pragma: no-cache");

    SPITHEADER();
 
    echo "<div class='row'>
          <div class='col-lg-6  col-lg-offset-3
                      col-md-6  col-md-offset-3
                      col-sm-8  col-sm-offset-2
                      col-xs-12 col-xs-offset-0'>\n";
    echo "<form id='quickvm_login_form' role='form'
            method='post' action='login.php'>\n";
    echo "<div class='panel panel-default'>
           <div class='panel-heading'>
              <h3 class='panel-title'>
                 Login</h3></div>
           <div class='panel-body form-horizontal'>\n";

    if ($error) {
        echo "<span class='help-block'><font color=red>";
    	switch ($error) {
        case "failed": 
            echo "Login attempt failed! Please try again.";
            break;
        case "notloggedin":
	    echo "You do not appear to be logged in!";
            break;
        case "timedout":
	    echo "Your login has timed out!";
	    break;
        case "alreadyloggedin":
	    echo "You are already logged in. Logout first?";
	    break;
	default:
	    echo "Unknown Error ($error)!";
        }
        echo "</font></span>";
    }
    elseif ($refer) {
        echo "<span class='help-block'>Please login before continuing</span>";
    }
    if ($referrer) {
	echo "<input type=hidden name=referrer value=$referrer>\n";
    }
?>
             <div class='form-group'>
                <label for='uid' class='col-sm-2 control-label'>Username</label>
                <div class='col-sm-10'>
                    <input name='uid' class='form-control'
                           placeholder='<?php echo $pwlab ?>'
                           autofocus type='text'>
                </div>
             </div>
             <div class='form-group'>
                <label for='password' class='col-sm-2 control-label'>Password
					  </label>
                <div class='col-sm-10'>
                   <input name='password' class='form-control'
                          placeholder='Password'
                          type='password'>
                </div>
             </div>
             <div class='form-group'>
               <div class='col-sm-offset-2 col-sm-10'>
                 <a class='btn btn-info btn-sm pull-left'
		    type='button' href='forgotpswd.php'
                    style='margin-right: 10px;'>
                    Forgot Password?</a>
<?php
    if ($ISCLOUD) {
	?>
                 <button class='btn btn-info btn-sm pull-left'
		    type='button'
                    data-toggle="tooltip" data-placement="left"
		    title="You can use your geni credentials to login"
                    id='quickvm_geni_login_button'>Geni User?</button>
        <?php
    }
    if ($ISAPT && REMEMBERED_ID() && $showguestlogin) {
	?>
                 <a class='btn btn-info btn-sm pull-left'
	            href='instantiate.php?asguest=1'
		    type='button'>Continue as Guest</a>
        <?php
    }
?>
                 <button class='btn btn-primary btn-sm pull-right'
                         id='quickvm_login_modal_button'
                         type='submit' name='login'>Login</button>
               </div>
             </div>
<?php
    echo "
            <br> 
           </div>
          </div>
          </form>
        </div>
        </div>\n";

    if ($ISCLOUD) {
	echo "<script
                src='https://www.emulab.net/protogeni/speaks-for/geni-auth.js'>
              </script>\n";
    }
    echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
    echo "<script src='js/lib/bootstrap.js'></script>\n";
    echo "<script src='js/lib/require.js' data-main='js/login'></script>";
    SPITFOOTER();
    return;
}
#
# If not clicked, then put up a form.
#
if (!$ajax_request && !isset($login)) {
    if ($this_user) {
	header("Location: $APTBASE/landing.php");
	return;
    }
    SPITFORM(REMEMBERED_ID(), $referrer, null);
    return;
}

#
# Login clicked.
#
$STATUS_LOGGEDIN  = 1;
$STATUS_LOGINFAIL = 2;
$login_status     = 0;

if (!isset($uid) || $uid == "" || !isset($password) || $password == "") {
    $login_status = $STATUS_LOGINFAIL;
}
else {
    $dologin_status = DOLOGIN($uid, $password);

    if ($dologin_status == DOLOGIN_STATUS_WEBFREEZE) {
	# Short delay.
	sleep(1);

	SPITHEADER();
	echo "<h3>
              Your account has been frozen due to earlier login attempt
              failures. You must contact $TBMAILADDR to have your account
              restored. <br> <br>
              Please do not attempt to login again; it will not work!
              </h3>\n";
        echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
        echo "<script src='js/lib/bootstrap.js'></script>\n";
        echo "<script src='js/lib/require.js' data-main='js/main'></script>";
	SPITFOOTER();
	return;
    }
    else if ($dologin_status == DOLOGIN_STATUS_OKAY) {
	$login_status = $STATUS_LOGGEDIN;
    }
    else {
	# Short delay.
	sleep(1);
	$login_status = $STATUS_LOGINFAIL;
    }
}

header("Last-Modified: " . gmdate("D, d M Y H:i:s") . " GMT");
header("Expires: Mon, 26 Jul 1997 05:00:00 GMT");
header("Cache-Control: no-cache, max-age=0, must-revalidate, no-store");
header("Pragma: no-cache");

#
# Failed, then try again with an error message.
# 
if ($login_status == $STATUS_LOGINFAIL) {
    if ($ajax_request) {
	SPITAJAX_ERROR(1, "login failed");
	exit(0);
    }
    SPITFORM($uid, $referrer, "failed");
    return;
}
if ($ajax_request) {
    SPITAJAX_RESPONSE("login sucessful");
    exit();
}
elseif (isset($referrer)) {
    #
    # Zap back to page that started the login request.
    #
    header("Location: $referrer");
}
else {
    header("Location: $APTBASE/landing.php");
}
?>
