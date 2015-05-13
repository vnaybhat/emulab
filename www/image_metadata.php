<?php
#
# Copyright (c) 2003-2012 University of Utah and the Flux Group.
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
include_once("imageid_defs.php");

function SPITERROR($code, $msg)
{
    header("HTTP/1.0 $code $msg");
    exit();
}

#
# Verify page arguments.
#
$reqargs = RequiredPageArguments("uuid", PAGEARG_STRING);

$image = Image::LookupByUUID($uuid);
if (! isset($image)) {
    SPITERROR(404, "Could not find $uuid!");
}
if (! $image->isglobal()) {
    SPITERROR(403, "No permission to access image");
}

$fp = popen("$TBSUEXEC_PATH nobody nobody webdumpdescriptor ".
	    "-e -i " . $image->imageid(), "r");
if (! $fp) {
    SPITERROR(404, "Could not get metadata for $uuid!");
}

header("Content-Type: text/plain; charset=us-ascii");
header("Expires: Mon, 26 Jul 1997 05:00:00 GMT");
header("Cache-Control: no-cache, must-revalidate");
header("Pragma: no-cache");
flush();

while (!feof($fp)) {
    $string = fgets($fp, 1024);
    echo "$string";
    flush();
}
pclose($fp);
$fp = 0;

?>
