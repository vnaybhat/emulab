#!/usr/bin/perl -wT
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

#
# This is a stub library to provide a few things that libtestbed on
# boss provides.
#
package libtestbed;
use Exporter;
@ISA    = "Exporter";
@EXPORT = qw( SENDMAIL TB_BOSSNODE TB_EVENTSERVER
	      TBScriptLock TBScriptUnlock
	      TBSCRIPTLOCK_OKAY TBSCRIPTLOCK_TIMEDOUT
	      TBSCRIPTLOCK_IGNORE TBSCRIPTLOCK_FAILED TBSCRIPTLOCK_GLOBALWAIT
	      TBSCRIPTLOCK_SHAREDLOCK TBSCRIPTLOCK_NONBLOCKING
	      TBSCRIPTLOCK_WOULDBLOCK
	      TBTimeStamp TBTimeStampWithDate TBBackGround ReOpenLog
	    );

# Must come after package declaration!
use English;
# For locking below
use Fcntl ':flock';
use IO::Handle;
use Time::HiRes qw(gettimeofday);

#
# Turn off line buffering on output
#
$| = 1;

# Load up the paths. Done like this in case init code is needed.
BEGIN
{
    if (! -e "/etc/emulab/paths.pm") {
	die("Yikes! Could not require /etc/emulab/paths.pm!\n");
    }
    require "/etc/emulab/paths.pm";
    import emulabpaths;
}

# Need this.
use libtmcc;

sub SENDMAILWith($$$$;$$@);

sub SENDMAIL($$$;$$@)
{
    my($To, $Subject, $Message, $From, $Headers, @Files) = @_;
    SENDMAILWith("/usr/sbin/sendmail -i -t", $To, $Subject, $Message, $From, $Headers, @Files);
}

sub SENDMAILWith($$$$;$$@)
{
    my($Command, $To, $Subject, $Message, $From, $Headers, @Files) = @_;
    my $tag = uc($MAILTAG);

    #
    # Untaint the path locally. Note that using a "local" fails on older perl!
    #
    my $SAVE_PATH = $ENV{'PATH'};
    $ENV{'PATH'} = "/bin:/usr/bin";
    delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};

    if (! open(MAIL, "| $Command")) {
	print STDERR "SENDMAIL: Could not start sendmail: $!\n";
	goto bad;
    }

    #
    # Sendmail will figure this out if not given.
    #
    if (defined($From) && $From) {
	print MAIL "From: $From\n";
    }
    if (defined($Headers) && length($Headers) > 0) {
	print MAIL "$Headers\n";
    }
    print MAIL "X-NetBed: $SCRIPTNAME\n";
    if (defined($To)) {
	print MAIL "To: $To\n";
    }
    print MAIL "Subject: $tag: $Subject\n";
    print MAIL "\n";
    print MAIL "$Message\n";
    print MAIL "\n";

    if (@Files) {
	foreach my $file ( @Files ) {
	    if (defined($file) && open(IN, "$file")) {
		print MAIL "\n--------- $file --------\n";

		while (<IN>) {
		    print MAIL "$_";
		}
		close(IN);
	    }
	}
    }

    print MAIL "\n";
    if (! close(MAIL)) {
	print STDERR "SENDMAIL: Could not finish sendmail: $!\n";
	goto bad;
    }
    $ENV{'PATH'} = $SAVE_PATH;
    return 1;

  bad:
    $ENV{'PATH'} = $SAVE_PATH;
    return 0;
}

#
# Put ourselves into the background, directing output to the log file.
# The caller provides the logfile name, which should have been created
# with mktemp, just to be safe. Returns the usual return of fork.
#
# usage int TBBackGround(char *filename).
#
sub TBBackGround($)
{
    my ($logname) = @_;

    my $mypid = fork();
    if ($mypid) {
	return $mypid;
    }
    select(undef, undef, undef, 0.2);

    #
    # We have to disconnect from the caller by redirecting both STDIN and
    # STDOUT away from the pipe. Otherwise the caller (the web server) will
    # continue to wait even though the parent has exited.
    #
    open(STDIN, "< /dev/null") or
	die("opening /dev/null for STDIN: $!");

    ReOpenLog($logname);

    #
    # Create a new session to ensure we are clear of any process group
    #
    POSIX::setsid() or
	die("setsid failed: $!");

    return 0;
}

#
# As for newsyslog. Call this on signal. newsyslog will have renamed the
# the original file already.
#
sub ReOpenLog($)
{
    my ($logname) = @_;

    # Note different taint check (allow /).
    if ($logname =~ /^([-\@\w.\/]+)$/) {
	$logname = $1;
    }
    else {
	die "Bad data in logfile name: $logname";
    }

    open(STDERR, ">> $logname") or die("opening $logname for STDERR: $!");
    open(STDOUT, ">> $logname") or die("opening $logname for STDOUT: $!");

    #
    # Turn off line buffering on output
    #
    STDOUT->autoflush(1);
    STDERR->autoflush(1);

    return 0;
}

#
# Return a timestamp. We don't care about day/date/year. Just the time mam.
#
# TBTimeStamp()
#
sub TBTimeStamp()
{
    my ($seconds, $microseconds) = gettimeofday();

    return POSIX::strftime("%H:%M:%S", localtime($seconds)) . ":$microseconds";
}

sub TBTimeStampWithDate()
{
    my ($seconds, $microseconds) = gettimeofday();

    return POSIX::strftime("%m/%d/20%y %H:%M:%S", localtime($seconds))
	. ":$microseconds";

}

#
# Return name of the bossnode.
#
sub TB_BOSSNODE()
{
    return tmccbossname();
}

#
# Return name of the event server.
#
sub TB_EVENTSERVER()
{
    # duplicate behavior of tmcc bossinfo function
    my @searchdirs = ( "/etc/testbed","/etc/emulab","/etc/rc.d/testbed",
		       "/usr/local/etc/testbed","/usr/local/etc/emulab" );
    my $bossnode = TB_BOSSNODE();
    my $eventserver = '';

    foreach my $d (@searchdirs) {
	if (-e "$d/eventserver" && !(-z "$d/eventserver")) {
	    $eventserver = `cat $d/eventserver`;
	    last;
	}
    }
    if ($eventserver eq '') {
	my @ds = split(/\./,$bossnode,2);
	if (scalar(@ds) == 2) {
	    # XXX event-server hardcode
	    $eventserver = "event-server.$ds[1]";
	}
    }
    if ($eventserver eq '') {
	$eventserver = "event-server";
    }

    return $eventserver;
}

#
# Serialize an operation (script).
#
my $lockname;
my $lockhandle;

# Return Values.
sub TBSCRIPTLOCK_OKAY()		{ 0;  }
sub TBSCRIPTLOCK_TIMEDOUT()	{ 1;  }
sub TBSCRIPTLOCK_IGNORE()	{ 2;  }
sub TBSCRIPTLOCK_WOULDBLOCK()	{ 4;  }
sub TBSCRIPTLOCK_FAILED()	{ -1; }
sub TBSCRIPTLOCK_GLOBALWAIT()	{ 0x01; }
sub TBSCRIPTLOCK_SHAREDLOCK()	{ 0x10; }
sub TBSCRIPTLOCK_NONBLOCKING()	{ 0x20; }

#
# There are two kinds of serialization.
#
#   * Usual Kind: Each party just waits the lock.
#   * Other Kind: Only the first party really needs to run; the others just
#                 need to wait. For example; exports_setup operates globally,
#                 so there is no reason to run it more then once. We just
#                 need to make sure that everyone waits for the one that is
#		  running to finish. Use the global option for this.
#
sub TBScriptLock($;$$$)
{
    my ($token, $flags, $waittime, $lockhandle_ref) = @_;
    local *LOCK;
    my $global = 0;
    my $shared = 0;

    if (!defined($waittime)) {
	$waittime = 30;
    }
    elsif ($waittime == 0) {
	$waittime = 99999999;
    }
    $global = 1
	if (defined($flags) && ($flags & TBSCRIPTLOCK_GLOBALWAIT()));
    $shared = 1
	if (defined($flags) && ($flags & TBSCRIPTLOCK_SHAREDLOCK()));
    $lockname = "/var/tmp/testbed_${token}_lockfile";

    my $oldmask = umask(0000);

    if (! open(LOCK, ">>$lockname")) {
	print STDERR "Could not open $lockname!\n";
	umask($oldmask);
	return TBSCRIPTLOCK_FAILED();
    }
    umask($oldmask);

    if (! $global) {
	#
	# A plain old lock.
	#
	my $tries = 0;
	my $ltype = ($shared ? LOCK_SH : LOCK_EX);
	while (flock(LOCK, $ltype|LOCK_NB) == 0) {
	    return TBSCRIPTLOCK_WOULDBLOCK()
		if (defined($flags) && ($flags & TBSCRIPTLOCK_NONBLOCKING()));
	    
	    print "Another $token is in progress (${tries}s). Waiting ...\n"
		if (($tries++ % 60) == 0);

	    $waittime--;
	    if ($waittime == 0) {
		print STDERR "Could not get the lock after a long time!\n";
		return TBSCRIPTLOCK_TIMEDOUT();
	    }
	    sleep(1);
	}
	# Okay, got the lock. Save the handle. We need it below.
	if (defined($lockhandle_ref)) {
	    $$lockhandle_ref = *LOCK;
	}
	else {
	    $lockhandle = *LOCK;
	}
	return TBSCRIPTLOCK_OKAY();
    }

    #
    # Okay, a global lock.
    #
    # If we don't get it the first time, we wait for:
    # 1) The lock to become free, in which case we do our thing
    # 2) The time on the lock to change, in which case we wait for that
    #    process to finish, and then we are done since there is no
    #    reason to duplicate what the just finished process did.
    #
    if (flock(LOCK, LOCK_EX|LOCK_NB) == 0) {
	my $oldlocktime = (stat(LOCK))[9];
	my $gotlock = 0;

	while (1) {
	    print "Another $token in progress. Waiting a moment ...\n";

	    if (flock(LOCK, LOCK_EX|LOCK_NB) != 0) {
		# OK, got the lock
		$gotlock = 1;
		last;
	    }
	    my $locktime = (stat(LOCK))[9];
	    if ($locktime != $oldlocktime) {
		$oldlocktime = $locktime;
		last;
	    }

	    $waittime--;
	    if ($waittime <= 0) {
		print STDERR "Could not get the lock after a long time!\n";
		return TBSCRIPTLOCK_TIMEDOUT();
	    }
	    sleep(1);
	}

	$count = 0;
	#
	# If we did not get the lock, wait for the process that did to finish.
	#
	if (!$gotlock) {
	    while (1) {
		if ((stat(LOCK))[9] != $oldlocktime) {
		    return TBSCRIPTLOCK_IGNORE();
		}
		if (flock(LOCK, LOCK_EX|LOCK_NB) != 0) {
		    close(LOCK);
		    return TBSCRIPTLOCK_IGNORE();
		}

		$waittime--;
		if ($waittime <= 0) {
		    print STDERR
			"Process with the lock did not finish after ".
			"a long time!\n";
		    return TBSCRIPTLOCK_TIMEDOUT();
		}
		sleep(1);
	    }
	}
    }
    #
    # Perl-style touch(1)
    #
    my $now = time;
    utime $now, $now, $lockname;

    if (defined($lockhandle_ref)) {
	$$lockhandle_ref = *LOCK;
    }
    else {
	$lockhandle = *LOCK;
    }
    return TBSCRIPTLOCK_OKAY();
}

#
# Unlock; Just need to close the file (releasing the lock).
#
sub TBScriptUnlock(;$)
{
    my ($lockhandle_arg) = @_;
    if (defined($lockhandle_arg)) {
	flock($lockhandle_arg, LOCK_UN);
	close($lockhandle_arg);
    }
    elsif (defined($lockhandle)) {
	flock($lockhandle, LOCK_UN);
	close($lockhandle);
	undef($lockhandle);
    }
}

1;

