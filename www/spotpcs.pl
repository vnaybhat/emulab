#!usr/bin/perl -w

require "/usr/testbed/local/preempt_nodes";

my $freeable = allocd_but_free_nodes();
print "$freeable\n";
