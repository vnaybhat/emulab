<?php
#
# Copyright (c) 2006-2014 University of Utah and the Flux Group.
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
#

$am_array = array('Utah DDC' =>
		     "urn:publicid:IDN+utahddc.geniracks.net+authority+cm",
		  'Utah APT' =>
		     "urn:publicid:IDN+apt.emulab.net+authority+cm",
		  'Utah PG'  =>
		     "urn:publicid:IDN+emulab.net+authority+cm");

class Instance
{
    var	$instance;
    
    #
    # Constructor by lookup on unique index.
    #
    function Instance($uuid) {
	$safe_uuid = addslashes($uuid);

	$query_result =
	    DBQueryWarn("select * from apt_instances ".
			"where uuid='$safe_uuid'");

	if (!$query_result || !mysql_num_rows($query_result)) {
	    $this->instance = null;
	    return;
	}
	$this->instance = mysql_fetch_array($query_result);
    }
    # accessors
    function field($name) {
	return (is_null($this->instance) ? -1 : $this->instance[$name]);
    }
    function uuid()	    { return $this->field('uuid'); }
    function slice_uuid()   { return $this->field('slice_uuid'); }
    function creator()	    { return $this->field('creator'); }
    function creator_idx()  { return $this->field('creator_idx'); }
    function creator_uuid() { return $this->field('creator_uuid'); }
    function created()	    { return $this->field('created'); }
    function profile_id()   { return $this->field('profile_id'); }
    function profile_version() { return $this->field('profile_version'); }
    function status()	    { return $this->field('status'); }
    function manifest()	    { return $this->field('manifest'); }
    function servername()   { return $this->field('servername'); }
    function IsAPT() {
	return preg_match('/aptlab/', $this->servername());
    }
    function IsCloud() {
	return preg_match('/cloudlab/', $this->servername());
    }
    
    # Hmm, how does one cause an error in a php constructor?
    function IsValid() {
	return !is_null($this->instance);
    }

    # Lookup up an instance by idx. 
    function Lookup($idx) {
	$foo = new Instance($idx);

	if ($foo->IsValid()) {
            # Insert into cache.
	    return $foo;
	}	
	return null;
    }

    function LookupByCreator($token) {
	$safe_token = addslashes($token);

	$query_result =
	    DBQueryFatal("select uuid from apt_instances ".
			 "where creator_uuid='$safe_token'");

	if (! ($query_result && mysql_num_rows($query_result))) {
	    return null;
	}
	$row = mysql_fetch_row($query_result);
	$uuid = $row[0];
 	return Instance::Lookup($uuid);
    }

    #
    # Refresh an instance by reloading from the DB.
    #
    function Refresh() {
	if (! $this->IsValid())
	    return -1;

	$uuid = $this->uuid();

	$query_result =
	    DBQueryWarn("select * from apt_instances where uuid='$uuid'");
    
	if (!$query_result || !mysql_num_rows($query_result)) {
	    $this->instance  = NULL;
	    return -1;
	}
	$this->instance = mysql_fetch_array($query_result);
	return 0;
    }
    #
    # Class function to create a new Instance
    #
    function Instantiate($creator, $options, $args, &$errors) {
	global $suexec_output, $suexec_output_array;

	# So we can look up the slice after the backend creates it.
	$uuid = NewUUID();

	#
        # Generate a temporary file and write in the XML goo. 
	#
	$xmlname = tempnam("/tmp", "quickvm");
	if (! $xmlname) {
	    TBERROR("Could not create temporary filename", 0);
	    $errors["error"] = "Transient error(1); please try again later.";
	    return null;
	}
	elseif (! ($fp = fopen($xmlname, "w"))) {
	    TBERROR("Could not open temp file $xmlname", 0);
	    $errors["error"] = "Transient error(2); please try again later.";
	    return null;
	}
	else {
	    fwrite($fp, "<quickvm>\n");
	    foreach ($args as $name => $value) {
		fwrite($fp, "<attribute name=\"$name\">");
		fwrite($fp, "  <value>" . htmlspecialchars($value) .
		       "</value>");
		fwrite($fp, "</attribute>\n");
	    }
	    fwrite($fp, "</quickvm>\n");
	    fclose($fp);
	    chmod($xmlname, 0666);
	}
	# 
	# With a real user, run as that user. 
	#
	$uid = ($creator ? $creator->uid() : "nobody");
	$pid = ($creator ? $creator->FirstApprovedProject()->pid() : "nobody");

	if (isset($_SERVER['REMOTE_ADDR'])) { 
	    putenv("REMOTE_ADDR=" . $_SERVER['REMOTE_ADDR']);
	}
	if (isset($_SERVER['SERVER_NAME'])) { 
	    putenv("SERVER_NAME=" . $_SERVER['SERVER_NAME']);
	}
	$retval = SUEXEC($uid, $pid,
			 "webcreate_instance $options -u $uuid $xmlname",
			 SUEXEC_ACTION_CONTINUE);

	if ($retval != 0) {
	    if ($retval < 0) {
		$errors["error"] =
		    "Transient error(3); please try again later.";
	    }
	    else {
		if (count($suexec_output_array)) {
		    $line = $suexec_output_array[0];
		    $errors["error"] = $line;
		}
		else {
		    $errors["error"] =
			"Transient error(4); please try again later.";
		}
	    }
	    return null;
	}
	unlink($xmlname);

	$instance = Instance::Lookup($uuid);
	if (!$instance) {
	    $errors["error"] = "Transient error(5); please try again later.";
	    return null;
	}
	if (!$creator) {
	    $creator = GeniUser::Lookup("sa", $instance->creator_uuid());
	}
	if (!$creator) {
	    $errors["error"] = "Transient error(6); please try again later.";
	    return null;
	}
	return array($instance, $creator);
    }

    function UserHasInstances($user) {
	$uuid = $user->uuid();

	$query_result =
	    DBQueryFatal("select uuid from apt_instances ".
			 "where creator_uuid='$uuid'");

	return mysql_num_rows($query_result);
    }

    function SendEmail($to, $subject, $msg, $headers) {
	TBMAIL($to, $subject, $msg, $headers);
    }
}
?>
