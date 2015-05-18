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
# Standard Testbed Header
#
PAGEHEADER("Testbed Status --- All time in hours");
$out = TBPrjUsageStats();

echo "<table border='1' align='center' style='border-color: silver;'>";  
echo "<tr>";  
echo "<th align='center'> &nbsp;&nbsp; Project Name &nbsp;&nbsp;</th>";
echo "<th align='center'> &nbsp;&nbsp; Quota &nbsp;&nbsp;</th>";
echo "<th align='center'> &nbsp;&nbsp; Usage &nbsp;&nbsp;</th>";
echo "<th align='center'> &nbsp;&nbsp; #pnodes &nbsp;&nbsp;</th>";
echo "<th align='center'> &nbsp;&nbsp; Time Left &nbsp;&nbsp;</th>";
echo "</tr>";
foreach ($out as $item) {
	$words = explode(',', $item);
    echo "<tr>";  
    echo "<td> $words[0] </td>";
    echo "<td> $words[1] </td>";
    echo "<td> $words[2] </td>";
    echo "<td> $words[3] </td>";
    echo "<td> $words[4] </td>";
    echo "</tr>";
}
echo "</table>";
echo "<br>";
echo " Quota=Total pnode hours over last 30 day period (sliding window)";
echo "<br>";

echo "Usage=Total pnode hours used by all experiments under this project over the last 30 days";
echo "<br>";
echo "#pnodes=Total number of nodes currently being used by all experiments under this project";
echo "<br>";
echo "Time Left=Approximation of when this project might become eligible for pre-emption if it continues to use resources in current state";
echo "<br>";

# Standard Testbed Footer
# 
PAGEFOOTER();
?>
