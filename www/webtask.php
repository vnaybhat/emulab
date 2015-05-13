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
class WebTask {
    var	$webtask;
    var $decoded = null;

    #
    # Constructor by lookup on unique ID
    #
    function WebTask($task_id) {
	$safe_id = addslashes($task_id);

	$query_result =
	    DBQueryWarn("select * from web_tasks ".
			"where task_id='$safe_id'");

	if (!$query_result || !mysql_num_rows($query_result)) {
	    $this->webtask = NULL;
	    return;
	}
	$this->webtask = mysql_fetch_array($query_result);
    }

    # Hmm, how does one cause an error in a php constructor?
    function IsValid() {
	return !is_null($this->webtask);
    }

    # Lookup by imageid
    function Lookup($id) {
	$foo = new WebTask($id);

	if (! $foo->IsValid())
	    return null;

	return $foo;
    }

    # Lookup by object.
    function LookupByObject($uuid) {
	$query_result =
	    DBQueryWarn("select task_id from web_tasks ".
			"where object_uuid='$uuid'");

	if (!$query_result || !mysql_num_rows($query_result)) {
	    return null;
	}
	$row = mysql_fetch_array($query_result);
	$idx = $row['task_id'];
	
	return WebTask::Lookup($idx);
    }

    # We delete from the web interface.
    function Delete() {
	$task_id = $this->task_id();
	DBQueryWarn("delete from web_tasks where task_id='$task_id'");
	return 0;
    }

    # accessors
    function field($name) {
	return (is_null($this->webtask) ? -1 : $this->webtask[$name]);
    }
    function task_id()		{ return $this->field("task_id"); }
    function created()		{ return $this->field("created"); }
    function modified()		{ return $this->field("modified"); }
    function process_id()	{ return $this->field("process_id"); }
    function object_uuid()	{ return $this->field("object_uuid"); }
    function exitcode()		{ return $this->field("exitcode"); }
    function exited()		{ return $this->field("exited"); }
    function task_data()	{ return $this->field("task_data"); }

    #
    # Return the task data as a real object intead of JSON
    #
    function TaskData() {
	if ($this->task_data()) {
	    return json_decode($this->task_data(), true);
	}
	else {
	    return array();
	}
    }
    # Return a specific value from the data.
    function TaskValue($key) {
	if ($this->task_data()) {
	    if (! $this->decoded) {
		$this->decoded = json_decode($this->task_data(), true);
	    }
	    if (array_key_exists($key, $this->decoded)) {
		return $this->decoded[$key];
	    }
	}
	return null;
    }

    function ValidTaskID($id) {
	if (preg_match("/^[-\w]+$/", $id)) {
	    return TRUE;
	}
	return FALSE;
    }

    function GenerateID() {
	return md5(uniqid(rand(),1));
    }
}
?>
