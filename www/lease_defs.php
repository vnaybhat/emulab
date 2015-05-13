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

class Lease
{
    var	$lease;
    var $attributes;

    #
    # Constructor by lookup on unique index.
    #
    function Lease($token) {
	$safe_token = addslashes($token);
	$query_result = null;

	if (preg_match("/^\d+$/", $token)) {
	    $query_result =
		DBQueryWarn("select * from project_leases ".
			    "where lease_idx='$safe_token'");
	}
	elseif (preg_match("/^\w+\-\w+\-\w+\-\w+\-\w+$/", $token)) {
	    $query_result =
		DBQueryWarn("select * from project_leases ".
			    "where uuid='$safe_token'");
	}
	if (!$query_result || !mysql_num_rows($query_result)) {
	    $this->lease = NULL;
	    return;
	}
	$this->lease = mysql_fetch_array($query_result);
	$lease_idx   = $this->lease_idx();

	#
	# Load the attributes.
	#
	$query_result =
	    DBQueryWarn("select attrkey,attrval ".
			"  from lease_attributes ".
			"  where lease_idx='$lease_idx'");
	if (!$query_result) {
	    $this->lease = NULL;
	    return;
	}
	$attrs = array();

	while ($row = mysql_fetch_array($query_result)) {
	    $key = $row["attrkey"];
	    $val = $row["attrval"];
	    $attrs[$key] = $val;
	}
	$this->attributes = $attrs;
    }

    # Hmm, how does one cause an error in a php constructor?
    function IsValid() {
	return !is_null($this->lease);
    }

    # Lookup.
    function Lookup($token) {
	$foo = new Lease($token);

	if (! $foo->IsValid()) {
	    return null;
	}
	return $foo;
    }
    # Lookup by name in a project
    function LookupByName($project, $name) {
	$pid       = $project->pid();
	$safe_name = addslashes($name);
	
	$query_result =
	    DBQueryFatal("select lease_idx from project_leases ".
			 "where pid='$pid' and lease_id='$safe_name'");

	if (mysql_num_rows($query_result) == 0) {
	    return null;
	}
	$row = mysql_fetch_array($query_result);
	return Lease::Lookup($row["lease_idx"]);
    }

    # accessors
    function field($name) {
	return (is_null($this->lease) ? -1 : $this->lease[$name]);
    } 
    function lease_idx()     { return $this->field("lease_idx"); }
    function idx()           { return $this->field("lease_idx"); }
    function lease_id()      { return $this->field("lease_id"); }
    function id()            { return $this->field("lease_id"); }
    function owner_uid()     { return $this->field("owner_uid"); }
    function uuid()          { return $this->field("uuid"); }
    function pid()           { return $this->field("pid"); }
    function gid()           { return $this->field("gid"); }
    function lease_type()    { return $this->field("type"); }
    function type()          { return $this->field("type"); }
    function inception()     { return $this->field("inception"); }
    function created()       { return $this->field("inception"); }
    function lease_end()     { return $this->field("lease_end"); }
    function expires()       { return $this->field("lease_end"); }
    function last_used()     { return $this->field("last_used"); }
    function state()	     { return $this->field("state"); }
    function locked()	     { return $this->field("locked"); }
    function locker_pid()    { return $this->field("locker_pid"); }

    function attribute($key) {
	if (array_key_exists($key, $this->attributes)) {
	    return $this->attributes[$key];
	}
	return null;
    }
    function size()	{ return $this->attribute("size"); }
    function fstype()	{ return $this->attribute("fstype"); }
    function islocal()  { return 1; }

    #
    # This is incomplete.
    #
    function AccessCheck($user, $access_type) {
        #
        # Admins do whatever they want.
        # 
	if (ISADMIN()) {
	    return 1;
	}
	if ($this->owner_uid() == $user->uid()) {
	    return 1;
	}
	return 0;
    }
    #
    # Form a URN for the dataset.
    #
    function URN() {
	global $OURDOMAIN;
	
	return "urn:publicid:IDN+${OURDOMAIN}+dataset+" . $this->id();
    }
    
}
?>
