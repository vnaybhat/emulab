/*
 * Copyright (c) 2000-2012 University of Utah and the Flux Group.
 * 
 * {{{EMULAB-LICENSE
 * 
 * This file is part of the Emulab network testbed software.
 * 
 * This file is free software: you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at
 * your option) any later version.
 * 
 * This file is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
 * License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this file.  If not, see <http://www.gnu.org/licenses/>.
 * 
 * }}}
 */

/*
 * Various constants that are reflected in the DB!
 */
#define	TBDB_FLEN_NODEID	(32 + 1)
#define	TBDB_FLEN_VNAME		(32 + 1)
#define	TBDB_FLEN_EID		(32 + 1)
#define	TBDB_FLEN_UID		(8  + 1)
#define	TBDB_FLEN_PID		(48 + 1)
#define	TBDB_FLEN_GID		(32 + 1)
#define	TBDB_FLEN_NODECLASS	(10 + 1)
#define	TBDB_FLEN_NODETYPE	(30 + 1)
#define	TBDB_FLEN_IP		(16 + 1)
#define	TBDB_FLEN_IPMASK	(16 + 1)
#define TBDB_FLEN_EVOBJTYPE	128
#define TBDB_FLEN_EVOBJNAME	128
#define TBDB_FLEN_EVEVENTTYPE	128
#define TBDB_FLEN_PRIVKEY	64
#define TBDB_FLEN_SFSHOSTID	128
#define TBDB_FLEN_RPMS		4096
#define TBDB_FLEN_TINYTEXT	(256 + 1)
#define TBDB_FLEN_UUID		(64 + 1)
#define TBDB_FLEN_BSVOL         (32 + 1)
#define TBDB_FLEN_IMAGENAME     (30 + 1)

/*
 * Event system stuff.
 *
 * If you add to these two lists, make sure you add to the arrays in tbdefs.c
 */
#define TBDB_OBJECTTYPE_TESTBED	"TBCONTROL"
#define TBDB_OBJECTTYPE_STATE	"TBNODESTATE"
#define TBDB_OBJECTTYPE_OPMODE	"TBNODEOPMODE"
#define TBDB_OBJECTTYPE_EXPTSTATE "TBEXPTSTATE"
#define TBDB_OBJECTTYPE_LINK	"LINK"
#define TBDB_OBJECTTYPE_TRAFGEN	"TRAFGEN"
#define TBDB_OBJECTTYPE_TIME	"TIME"
#define TBDB_OBJECTTYPE_PROGRAM	"PROGRAM"
#define TBDB_OBJECTTYPE_FRISBEE	"FRISBEE"
#define TBDB_OBJECTTYPE_SIMULATOR "SIMULATOR"
#define TBDB_OBJECTTYPE_LINKTEST "LINKTEST"
#define TBDB_OBJECTTYPE_NSE     "NSE"
#define TBDB_OBJECTTYPE_CANARYD  "CANARYD"
#define TBDB_OBJECTTYPE_NODE     "NODE"
#define TBDB_OBJECTTYPE_GROUP    "GROUP"
#define TBDB_OBJECTTYPE_TIMELINE "TIMELINE"
#define TBDB_OBJECTTYPE_SEQUENCE "SEQUENCE"
#define TBDB_OBJECTTYPE_CONSOLE  "CONSOLE"
#define TBDB_OBJECTTYPE_TOPOGRAPHY "TOPOGRAPHY"
#define TBDB_OBJECTTYPE_LINKTRACE "LINKTRACE"
#define TBDB_OBJECTTYPE_EVPROXY "EVPROXY"
#define TBDB_OBJECTTYPE_BGMON "BGMON"
#define TBDB_OBJECTTYPE_DISK "DISK"
#define TBDB_OBJECTTYPE_CUSTOM "CUSTOM"
#define TBDB_OBJECTTYPE_PLABSCHED "PLABSCHED"

#define TBDB_EVENTTYPE_START	"START"
#define TBDB_EVENTTYPE_STOP	"STOP"
#define TBDB_EVENTTYPE_KILL	"KILL"
#define TBDB_EVENTTYPE_ISUP	"ISUP"
#define TBDB_EVENTTYPE_REBOOT	"REBOOT"
#define TBDB_EVENTTYPE_UP	"UP"
#define TBDB_EVENTTYPE_DOWN	"DOWN"
#define TBDB_EVENTTYPE_UPDATE	"UPDATE"
#define TBDB_EVENTTYPE_MODIFY	"MODIFY"
#define TBDB_EVENTTYPE_SET	"SET"
#define TBDB_EVENTTYPE_RESET	"RESET"
#define TBDB_EVENTTYPE_HALT	"HALT"
#define TBDB_EVENTTYPE_SWAPOUT	"SWAPOUT"
#define TBDB_EVENTTYPE_NSESWAP	"NSESWAP"
#define TBDB_EVENTTYPE_NSEEVENT	"NSEEVENT"
#define TBDB_EVENTTYPE_REPORT	"REPORT"
#define TBDB_EVENTTYPE_ALERT	"ALERT"
#define TBDB_EVENTTYPE_SETDEST  "SETDEST"
#define TBDB_EVENTTYPE_SNAPSHOT	"SNAPSHOT"
#define TBDB_EVENTTYPE_RELOAD	"RELOAD"
#define TBDB_EVENTTYPE_COMPLETE	"COMPLETE"
#define TBDB_EVENTTYPE_CLEAR	"CLEAR"
#define TBDB_EVENTTYPE_DEBUG	"DEBUG"
#define TBDB_EVENTTYPE_LOG	"LOG"
#define TBDB_EVENTTYPE_MESSAGE	"MESSAGE"
#define TBDB_EVENTTYPE_RUN	"RUN"
#define TBDB_EVENTTYPE_CREATE	"CREATE"
#define TBDB_EVENTTYPE_STOPRUN	"STOPRUN"

/*
 * Global event passthru sentinal - does _NOT_ go in either event array
 */
#define TBDB_EVENTEXPT_NONE     "__none"

#define TBDB_NODESTATE_ISUP       "ISUP"
#define TBDB_NODESTATE_REBOOTED   "REBOOTED"
#define TBDB_NODESTATE_REBOOTING  "REBOOTING"
#define TBDB_NODESTATE_SHUTDOWN   "SHUTDOWN"
#define TBDB_NODESTATE_BOOTING    "BOOTING"
#define TBDB_NODESTATE_TBSETUP    "TBSETUP"
#define TBDB_NODESTATE_RELOADSETUP "RELOADSETUP"
#define TBDB_NODESTATE_RELOADING  "RELOADING"
#define TBDB_NODESTATE_RELOADDONE "RELOADDONE"
#define TBDB_NODESTATE_RELOADDONE_V2 "RELOADDONEV2"
#define TBDB_NODESTATE_UNKNOWN    "UNKNOWN"
#define TBDB_NODESTATE_PXEWAIT    "PXEWAIT"
#define TBDB_NODESTATE_PXEWAKEUP  "PXEWAKEUP"
#define TBDB_NODESTATE_PXEBOOTING "PXEBOOTING"

#define TBDB_NODEOPMODE_NORMAL      "NORMAL"
#define TBDB_NODEOPMODE_DELAYING    "DELAYING"
#define TBDB_NODEOPMODE_UNKNOWNOS   "UNKNOWNOS"
#define TBDB_NODEOPMODE_RELOADING   "RELOADING"
#define TBDB_NODEOPMODE_NORMALv1    "NORMALv1" 
#define TBDB_NODEOPMODE_MINIMAL     "MINIMAL" 
#define TBDB_NODEOPMODE_RELOAD      "RELOAD" 
#define TBDB_NODEOPMODE_DELAY       "DELAY" 
#define TBDB_NODEOPMODE_BOOTWHAT    "_BOOTWHAT_"
#define TBDB_NODEOPMODE_UNKNOWN     "UNKNOWN"

#define TBDB_TBCONTROL_RESET        "RESET"
#define TBDB_TBCONTROL_RELOADDONE   "RELOADDONE"
#define TBDB_TBCONTROL_RELOADDONE_V2 "RELOADDONEV2"
#define TBDB_TBCONTROL_TIMEOUT      "TIMEOUT"

#define TBDB_IFACEROLE_CONTROL		"ctrl"
#define TBDB_IFACEROLE_EXPERIMENT	"expt"
#define TBDB_IFACEROLE_JAIL		"jail"
#define TBDB_IFACEROLE_FAKE		"fake"
#define TBDB_IFACEROLE_GW		"gw"
#define TBDB_IFACEROLE_OTHER		"other"

/* PLAB_SCHED entry for filtering events */
#define TBDB_PLABSCHED "PLABSCHED"

/*
 * Protos.
 */
int	tbdb_validobjecttype(char *foo);
int	tbdb_valideventtype(char *foo);
