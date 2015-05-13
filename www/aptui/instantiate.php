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
include_once("osinfo_defs.php");
include_once("geni_defs.php");
chdir("apt");
include("quickvm_sup.php");
include("instance_defs.php");
include("profile_defs.php");
$page_title = "Instantiate a Profile";
$dblink = GetDBLink("sa");

#
# Get current user but make sure coming in on SSL.
#
RedirectSecure();
$this_user = CheckLogin($check_status);
if ($ISCLOUD) {
    if (! ($CHECKLOGIN_STATUS & CHECKLOGIN_LOGGEDIN)) {
	header("Location: login.php");
    }
}

#
# Verify page arguments.
#
$optargs = OptionalPageArguments("create",        PAGEARG_STRING,
				 "profile",       PAGEARG_STRING,
				 "version",       PAGEARG_INTEGER,
				 "stuffing",      PAGEARG_STRING,
				 "verify",        PAGEARG_STRING,
				 "project",       PAGEARG_PROJECT,
				 "asguest",       PAGEARG_BOOLEAN,
				 "formfields",    PAGEARG_ARRAY);

if ($ISAPT && !$this_user) {
    #
    # If user appears to have an account, go to login page.
    # Continue as guest on that page.
    #
    if (REMEMBERED_ID()) {
	if (isset($asguest) && $asguest) {
	    # User clicked on continue as guest. If we do not delete the
	    # cookie, then user will go through the same loop next time
            # they click the Home button, since that points here. So delete
	    # the UID cookie. Not sure I like this.
	    ClearRememberedID();
	}
	else {
	    header("Location: login.php?from=instantiate");
	}
    }
}

if ($ISCLOUD) {
    $profile_default     = "OpenStack";
    $profile_default_pid = "tbres";
}
else {
    $profile_default     = "OneVM";
    $profile_default_pid = $TBOPSPID;
}
$profile_array    = array();

#
# if using the super secret URL, make sure the profile exists, and
# add to the array now since it might not be public or belong to the user.
#
if (isset($profile)) {
    #
    # Guest users must use the uuid, but logged in users may use the
    # internal index. But, we have to support simple the URL too, which
    # is /p/project/profilename, but only for public profiles.
    #
    if (isset($project) && isset($profile)) {
	$obj = Profile::LookupByName($project, $profile, $version);
    }
    elseif ($this_user || IsValidUUID($profile)) {
	$obj = Profile::Lookup($profile);
    }
    else {
	SPITUSERERROR("Illegal profile for guest user: $profile");
	exit();
    }
    if (! $obj) {
	SPITUSERERROR("No such profile: $profile");
	exit();
    }
    if (IsValidUUID($profile)) {
	#
	# If uuid was to profile, then find the most recently published
	# version and instantiate that, since what we have is the most
	# recent version, but might not be published.
	#
	if ($profile == $obj->profile_uuid() && !$obj->published()) {
	    $obj = $obj->LookupMostRecentPublished();
	    if (! $obj) {
		SPITUSERERROR("No published version for profile");
		exit();
	    }
	    $profile = $obj->uuid();
	}
	$profile_array[$profile] = $obj->name();
	$profilename = $obj->name();
    }
    else {
	#
	# If no version provided, then find the most recently published
	# version and instantiate that, since what we have is the most
	# recent version, but might not be published.
	#
	if (!isset($version) && !$obj->published()) {
	    $obj = $obj->LookupMostRecentPublished();
	    if (! $obj) {
		SPITUSERERROR("No published version for profile");
		exit();
	    }
	}
	 
	#
	# Must be public or belong to user. 
	#
	if (! ($obj->ispublic() ||
	       (isset($this_user) &&
		$obj->creator_idx() == $this_user->uid_idx()))) {
	    SPITUSERERROR("No permission to use profile: $profile");
	    exit();
	}
	$profile = $obj->uuid();
	$profile_array[$profile] = $obj->name();
	$profilename = $obj->name();
    }
}
else {
    #
    # Find all the public and user profiles. We use the UUID instead of
    # indicies cause we do not want to leak internal DB state to guest
    # users. Need to decide on what clause to use, depending on whether
    # a guest user or not.
    #
    $joinclause   = "";
    $whereclause  = "";
    if (!isset($this_user)) {
	$whereclause = "p.public=1";
    }
    else {
	$this_idx = $this_user->uid_idx();
	$joinclause =
	    "left join group_membership as g on ".
	    "     g.uid_idx='$this_idx' and ".
	    "     g.pid_idx=v.pid_idx and g.pid_idx=g.gid_idx";
	$whereclause =
	    "p.public=1 or p.shared=1 or v.creator_idx='$this_idx' or ".
	    "g.uid_idx is not null ";
    }

    $query_result =
	DBQueryFatal("select p.*,v.* from apt_profiles as p ".
		     "left join apt_profile_versions as v on ".
		     "     v.profileid=p.profileid and ".
		     "     v.version=p.version ".
		     "$joinclause ".
		     "where locked is null and ($whereclause)");
    while ($row = mysql_fetch_array($query_result)) {
	$profile_array[$row["uuid"]] = $row["name"];
	if ($row["pid"] == $profile_default_pid &&
	    $row["name"] == $profile_default) {
	    $profile_default = $row["uuid"];
	}
    }
}

function SPITFORM($formfields, $newuser, $errors)
{
    global $TBBASE, $APTMAIL, $ISCLOUD;
    global $profile_array, $this_user, $profilename, $profile, $am_array;
    $showabout = ($ISCLOUD || !$this_user ? 1 : 0);

    # XSS prevention.
    while (list ($key, $val) = each ($formfields)) {
	$formfields[$key] = CleanString($val);
    }
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

    echo "<div class='row'>
          <div class='col-lg-6  col-lg-offset-3
                      col-md-6  col-md-offset-3
                      col-sm-8  col-sm-offset-2
                      col-xs-12 col-xs-offset-0'>\n";

    # Placeholder for the "about" panel, which is now a template file.
    echo "<div id='about_div'></div>\n";

    echo "<form id='quickvm_form' role='form'
            enctype='multipart/form-data'
            method='post' action='instantiate.php'>\n";
    if (!$this_user) {
	echo "<div class='panel panel-default'>
                <div class='panel-heading'>
                   <h3 class='panel-title'>\n";
    }
    else {
	echo "<h3 style='margin-top: 0px;'>";
    }
    echo "<center>Run an Experiment";
    if (isset($profilename)) {
        echo " using profile &quot;$profilename&quot";
    }
    echo "</center></h3>\n";
    if (!$this_user) {
	echo "   </div>
	      <div class='panel-body'>\n";
    }
    
    #
    # If linked to a specific profile, description goes here
    #
    if ($profile) {
	if (!$this_user) {
	    echo "  <p>Fill out the form below to run an experiment ".
		"using this profile:</p>\n";
	}
        # Note: Following line is also duplicated below
        echo "  <blockquote><p><span id='selected_profile_description'></span></p></blockquote>\n";
        echo "  <p>When you click the &quot;Create&quot; button, the virtual or
                   physical machines described in the profile will be booted
                   on Apt's hardware<p>\n";
    }

    echo "   <fieldset>\n";

    #
    # Look for non-specific error.
    #
    if ($errors && array_key_exists("error", $errors)) {
	echo "<font color=red><center>" . $errors["error"] .
	    "</center></font><br>";
    }

    #
    # Ask for user information
    #
    if (!isset($this_user)) {
	$formatter("username", 
		  "<input name=\"formfields[username]\"
		          value='" . $formfields["username"] . "'
                          class='form-control'
                          placeholder='Pick a user name'
                          autofocus type='text'>");
   
	$formatter("email", 
		  "<input name=\"formfields[email]\"
                          type='text'
                          value='" . $formfields["email"] . "'
                          class='form-control'
                          placeholder='Your email address' type='text'>");
    }
    # We put the ssh stuff in two different places, so make it a function.
    $spitsshkeystuff = function() use ($formfields, $formatter) {
	if ($formfields["sshkey"] == "") {
	    $title_text = "<span class='text-warning'>
                    No SSH key, browser shell only!<span>";
	    $expand_text = "Add Key";
	}
	else {
	    $title_text = "<span class='text-info'>
                    Your SSH key</span>";
	    $expand_text = "Update";
	}
        echo "<div class='form-group row' style='margin-bottom: 0px;'>";
        echo "  <div class='col-md-12'>
                  <div class='panel panel-default'>\n";
        echo "      <div class='panel-heading'>$title_text
                     <a class='pull-right'
                        data-toggle='collapse' href='#mysshkey'>
                      $expand_text</a>\n";
        echo "      </div>\n";
	echo "      <div id='mysshkey' class='panel-collapse collapse'>\n";
        echo "       <div class='panel-body'>";
	
	$formatter("keyfile",
		   "<span class='help-block'>
                     Upload a file or paste it in the text box. This will ".
		   "allow you to login using your favorite ssh client. Without ".
		   "a SSH key, you will be limited to using a shell window in ".
		   "your browser. If you already see a key here, you can ".
		   "change it and we will remember your new key for next time. ".
                   "Don't know how to generate your SSH key? ".
		   "See <a href='https://help.github.com/articles/generating-ssh-keys'>this tutorial.</a></span>".
		   "<input type=file name='keyfile'>");

	$formatter("sshkey", 
		  "<textarea name=\"formfields[sshkey]\" 
                             placeholder='Paste in your ssh public key.'
                             class='form-control'
                             rows=4 cols=45>" . $formfields["sshkey"] .
                  "</textarea>");

        echo "       </div>";
        echo "       <div class='clearfix'></div>";
        echo "      </div>";
        echo "    </div>";
        echo "</div></div>"; # End of panel/row.
    };
    if (!isset($this_user)) {
	$spitsshkeystuff();
    }

    #
    # Only print profile selection box if we weren't linked to a specific
    # profile
    #
    if (!isset($profile)) {
        echo "<div class='form-group row' style='margin-bottom: 0px;'>";
        echo "<input id='selected_profile' type='hidden' 
                       name='formfields[profile]'/>";
        echo "<div class='col-md-12'><div class='panel panel-default'>\n";
        echo "<div class='panel-heading'>
                  <span class='panel-title'><strong>Selected Profile:</strong> 
                  <span id='selected_profile_text'>
                  </span></span>\n";
        if ($errors && array_key_exists("profile", $errors)) {
            echo "<label class='control-label' for='inputError'>" .
                $errors["profile"] .
                " </label>\n";
        }
        echo " </div>\n";
        # Note: Following line is also duplicated above
        echo "<div class='panel-body'>";
        echo "  <div id='selected_profile_description'></div>\n";
        echo "</div>";
        echo "<div class='panel-footer'>";
        echo "<button id='profile' class='btn btn-primary btn-md pull-right' 
                         type='button' name='profile_button'>
                    Change Profile
                  </button>";
        echo "<div class='clearfix'></div>";
        echo "</div>";
        echo "</div></div></div>"; # End of panel/row.
    }
    else {
	echo "<input id='selected_profile' type='hidden'
                     name='formfields[profile]'
                     value='" . $formfields["profile"] . "'>\n";

	# Send the original argument for the initial array stuff above.
        # Needs more work.
	echo "<input type='hidden' name='profile' value='$profile'>\n";
    }
    if (isset($this_user)) {
	$spitsshkeystuff();	
    }

    if (isset($this_user) && (ISADMIN() || STUDLY())) {
	$am_options = "";
	while (list($am, $urn) = each($am_array)) {
	    $selected = "";
	    if ($formfields["where"] == $am) {
		$selected = "selected";
	    }
	    $am_options .= 
		"<option $selected value='$am'>$am</option>\n";
	}
	$formatter("where",
		   "<select name=\"formfields[where]\"
		              id='profile_where' class='form-control'>".
		   "$am_options</select>");
    }
    echo "</fieldset>
           <div class='form-group row'>
           <div class='col-md-6 col-md-offset-3'>
           <button class='btn btn-success btn-block' id='instantiate_submit'
              type='submit' name='create'>Create!
           </button>
           </div>
           </div>
        </div>\n";
    if (!isset($this_user)) {
        echo "</div>
              </div>\n";
	SpitVerifyModal("verify_modal", "Create");
    
	if ($newuser) {
	    if (is_string($newuser)) {
		$stuffing = $newuser;
	    }
	    else {
		$stuffing = substr(GENHASH(), 0, 16);
	    }
	    mail($formfields["email"],
		 "aptlab.net: Verification code for creating your experiment",
		 "Here is your user verification code. Please copy and\n".
		 "paste this code into the box on the experiment page.\n\n".
		 "      $stuffing\n",
		 "From: $APTMAIL");
	    echo "<input type='hidden' name='stuffing' value='$stuffing' />";
	}
    }
    echo "</div>\n";
    echo "</form>\n";

    SpitTopologyViewModal("quickvm_topomodal", $profile_array);
    SpitWaitModal("waitwait");

    echo "<script type='text/javascript'>\n";
    echo "    window.PROFILE   = '" . $formfields["profile"] . "';\n";
    echo "    window.AJAXURL   = 'server-ajax.php';\n";
    echo "    window.SHOWABOUT = $showabout;\n";
    if ($newuser) {
	echo "window.APT_OPTIONS.isNewUser = true;\n";
    }
    echo "</script>\n";
    echo "<script src='js/lib/jquery-2.0.3.min.js'></script>\n";
    echo "<script src='js/lib/bootstrap.js'></script>\n";
    echo "<script src='js/lib/require.js' data-main='js/instantiate'></script>";
}

if (!isset($create)) {
    $defaults = array();
    $defaults["username"] = "";
    $defaults["email"]    = "";
    $defaults["sshkey"]   = "";
    $defaults["profile"]  = (isset($profile) ? $profile : $profile_default);
    $defaults["where"]    = 'Utah DDC';
	
    # 
    # Look for current user or cookie that tells us who the user is. 
    #
    if ($this_user) {
	$defaults["username"] = $this_user->uid();
	$defaults["email"]    = $this_user->email();
	if (1 || $this_user->IsAPT() || $this_user->IsCloud()) {
	    $sshkeys = $this_user->GetSSHKeys();
	    if (count($sshkeys)) {
		$defaults["sshkey"] = $sshkeys[0];
	    }
	}
    }
    elseif (isset($_COOKIE['quickvm_user'])) {
	$geniuser = GeniUser::Lookup("sa", $_COOKIE['quickvm_user']);
	if ($geniuser) {
	    #
	    # Look for existing quickvm. User not allowed to create
	    # another one.
	    #
	    $instance = Instance::LookupByCreator($geniuser->uuid());
	    if ($instance && $instance->status() != "terminating") {
		header("Location: status.php?oneonly=1&uuid=" .
		       $instance->uuid());
		return;
	    }
	    $defaults["username"] = $geniuser->name();
	    $defaults["email"]    = $geniuser->email();
	    $defaults["sshkey"]   = $geniuser->SSHKey();
	}
    }
    SPITFORM($defaults, false, array());
    SPITFOOTER();
    return;
}
#
# Otherwise, must validate and redisplay if errors
#
$errors = array();
$args   = array();

if (!$this_user) {
    #
    # These check do not matter for a logged in user; we ignore the values.
    #
    if (!isset($formfields["email"]) || $formfields["email"] == "") {
	$errors["email"] = "Missing Field";
    }
    elseif (! TBvalid_email($formfields["email"])) {
	$errors["email"] = TBFieldErrorString();
    }
    if (!isset($formfields["username"]) || $formfields["username"] == "") {
	$errors["username"] = "Missing Field";
    }
    elseif (! TBvalid_uid($formfields["username"])) {
	$errors["username"] = TBFieldErrorString();
    }
    elseif (User::LookupByUid($formfields["username"])) {
        # Do not allow uid overlap with real users.
	$errors["username"] = "Already in use - if you have an Emulab account, log in first";
    }
}
if (!isset($formfields["profile"]) || $formfields["profile"] == "") {
    $errors["profile"] = "No selection made";
}
elseif (! array_key_exists($formfields["profile"], $profile_array)) {
    $errors["profile"] = "Invalid Profile: " . $formfields["profile"];
}

#
# More sanity checks. 
#
if (!$this_user) {
    $geniuser = GeniUser::LookupByEmail("sa", $formfields["email"]);
    if ($geniuser) {
	if ($geniuser->name() != $formfields["username"]) {    
            $errors["email"] = "Already in use by another guest user";
	    unset($geniuser);
	}
    }
}

#
# Allow admin users to select the Aggregate. Experimental.
#
$aggregate_urn = "";

if ($this_user && (ISADMIN() || STUDLY())) {
    if (isset($formfields["where"]) && $formfields["where"] != "") {
	if (array_key_exists($formfields["where"], $am_array)) {
	    $aggregate_urn = $am_array[$formfields["where"]];
	}
	else {
	    $errors["where"] = "Invalid Aggregate";
	}
    }
}

if (count($errors)) {
    SPITFORM($formfields, false, $errors);
    SPITFOOTER();
    return;
}

#
# SSH keys are now optional for guest users; they just have to
# use the web based ssh window.
#
# Backend verifies pubkey and returns error. We first look for a 
# file and then fall back to an inline field.
#
if (isset($_FILES['keyfile']) &&
    $_FILES['keyfile']['name'] != "" &&
    $_FILES['keyfile']['name'] != "none") {

    $localfile = $_FILES['keyfile']['tmp_name'];
    $args["sshkey"] = file_get_contents($localfile);
    #
    # The filename will be lost on another trip through the browser.
    # So stick the key into the box.
    #
    $formfields["sshkey"] = $args["sshkey"];
}
elseif (isset($formfields["sshkey"]) && $formfields["sshkey"] != "") {
    $args["sshkey"] = $formfields["sshkey"];
}

if (count($errors)) {
    SPITFORM($formfields, false, $errors);
    SPITFOOTER();
    return;
}
# Silently ignore the form for a logged in user. 
$args["username"] = ($this_user ? $this_user->uid() : $formfields["username"]);
$args["email"]    = ($this_user ? $this_user->email() : $formfields["email"]);
$args["profile"]  = $formfields["profile"];

#
# See if user exists and is verified. We send email with a code, which
# they have to paste back into a box we add to the form. See above.
#
# We also get here if the user exists, but the browser did not have
# the tokens, as will happen if switching to another browser. We
# force the user to repeat the verification with the same code we
# have stored in the DB.
#
if (!$this_user &&
    (!$geniuser || !isset($_COOKIE['quickvm_authkey']) ||
     $_COOKIE['quickvm_authkey'] != $geniuser->auth_token())) {
    if (isset($stuffing) && $stuffing != "") {
	if (! (isset($verify) && $verify == $stuffing)) {
	    SPITFORM($formfields, $stuffing, $errors);
	    SPITFOOTER();
	    return;
	}
	#
	# If this is an existing user and they give us the right code,
	# we can check again for an existing VM and redirect to the
	# status page, like we do above.
	#
	if ($geniuser) {
	    $instance = Instance::LookupByCreator($geniuser->uuid());
	    if ($instance && $instance->status() != "terminating") {
		# Reset this cookie so status page is happy and so we
                # will stop asking.
		setcookie("quickvm_user",
			  $geniuser->uuid(), time() + (24 * 3600 * 30),
			  "/", $TBAUTHDOMAIN, 0);
		header("Location: status.php?oneonly=1&uuid=" .
		       $instance->uuid());
		return;
	    }
	}
	# Pass to backend to save in user object.
	$args["auth_token"] = $stuffing;
    }
    else {
	# Existing user, use existing auth token.
	# New user, we create a new one.
	$token = ($geniuser ? $geniuser->auth_token() : true);

	SPITFORM($formfields, $token, $errors);
	SPITFOOTER();
	return;
    }
}

# Admins can change aggregate.
$options      = ($aggregate_urn != "" ? " -a '$aggregate_urn'" : "");

#
# Invoke the backend.
#
list ($instance, $creator) =
    Instance::Instantiate($this_user, $options, $args, $errors);

if (!$instance) {
    SPITFORM($formfields, false, $errors);
    SPITFOOTER();
    return;
}
    
#
# Remember the user and auth key so that we can verify.
#
# The cookie handling is a pain since we run this under the aptlab
# virtual host, but the config uses a different domain, and so the
# cookies do not work. So, we have to look at our SERVER_NAME and
# set the cookie appropriately. 
#
if (!$this_user) {
    $cookiedomain = $TBAUTHDOMAIN;

    setcookie("quickvm_user",
	      $creator->uuid(), time() + (24 * 3600 * 30),
	      "/", $cookiedomain, 0);
    setcookie("quickvm_authkey",
	      $creator->auth_token(), time() + (24 * 3600 * 30),
	      "/", $cookiedomain, 0);
}
header("Location: status.php?uuid=" . $instance->uuid());
?>
