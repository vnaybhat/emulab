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

class Dataset
{
    var	$dataset;

    #
    # Constructor by lookup on unique index.
    #
    function Dataset($token) {
	$safe_token = addslashes($token);
	$query_result = null;

	if (preg_match("/^\d+$/", $token)) {
	    $query_result =
		DBQueryWarn("select * from apt_datasets ".
			    "where idx='$safe_token'");
	}
	elseif (preg_match("/^\w+\-\w+\-\w+\-\w+\-\w+$/", $token)) {
	    $query_result =
		DBQueryWarn("select * from apt_datasets ".
			    "where uuid='$safe_token'");
	}
	if (!$query_result || !mysql_num_rows($query_result)) {
	    $this->dataset = NULL;
	    return;
	}
	$this->dataset = mysql_fetch_array($query_result);
    }

    # Hmm, how does one cause an error in a php constructor?
    function IsValid() {
	return !is_null($this->dataset);
    }

    # Lookup by idx.
    function Lookup($token) {
	$foo = new Dataset($token);

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
	    DBQueryFatal("select idx from apt_datasets ".
			 "where pid='$pid' and dataset_id='$safe_name'");

	if (mysql_num_rows($query_result) == 0) {
	    return null;
	}
	$row = mysql_fetch_array($query_result);
	return Dataset::Lookup($row["idx"]);
    }

    # accessors
    function field($name) {
	return (is_null($this->dataset) ? -1 : $this->dataset[$name]);
    } 
    function idx()           { return $this->field("idx"); }
    function dataset_id()    { return $this->field("dataset_id"); }
    function id()            { return $this->field("dataset_id"); }
    function creator_uid()   { return $this->field("creator_uid"); }
    function owner_uid()     { return $this->field("creator_uid"); }
    function uuid()          { return $this->field("uuid"); }
    function pid()           { return $this->field("pid"); }
    function pid_idx()       { return $this->field("pid_idx"); }
    function gid()           { return $this->pid(); }
    function aggregate_urn() { return $this->field("aggregate_urn"); }
    function type()          { return $this->field("type"); }
    function fstype()        { return $this->field("fstype"); }
    function created()       { return $this->field("created"); }
    function expires()       { return $this->field("expires"); }
    function last_used()     { return $this->field("last_used"); }
    function state()	     { return $this->field("state"); }
    function size()	     { return $this->field("size"); }
    function locked()	     { return $this->field("locked"); }
    function locker_pid()    { return $this->field("locker_pid"); }
    function islocal()       { return 0; }

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
	if ($this->creator_uid() == $user->uid()) {
	    return 1;
	}
	return 0;
    }

    #
    # Form a URN for the dataset.
    #
    function URN() {
	if (!preg_match("/^([^\+]+)\+([^\+]+)/",
			$this->aggregate_urn(), $matches)) {
	    return "";
	}
	return $matches[1] . "+" . $matches[2] . "+dataset+" . $this->id();
    }
}
?>
