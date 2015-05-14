#!usr/bin/perl -w

require "/usr/testbed/local/preempt_nodes";

my $TB         = "/usr/testbed";
my $QUOTA_FILE = "$TB/proj_quota";

my $stats  = get_proj_stats();
my $projs  = $$stats{'u_proj'};
my $pnodes = $$stats{'nodes'};

my @keys   = sort { $$projs{$b} <=> $$projs{$a} } keys %{$projs};

# Read quotas for each project and create a hash map
my($qf, $line, @words, %quotas);
open($qf, '<', $QUOTA_FILE) or return;
while($line = <$qf>)  {
	@words = split(/ /, $line);

    # Only the first entry in the file is considered as the correct quota
	$quotas{$words[0]} = $words[1] unless exists $quotas{$words[0]};
}
close $qf;

my $quotas1 = get_proj_quota();
# get the mapping from pid_idx to pid, needed to display pid
my $pids = get_pididx_to_pid();

# For each pidx, caluclate the pnode-hours usage and the time 
#  remaining before an experiment from that project will be pre-empted
my($pid, $usghrs, $remaining, $num_nodes);
for my $pidx (@keys) {
	$pid    = $$pids{$pidx};
	$usghrs = $$projs{$pidx} / (60 * 60);
	$quota = $$quotas1{$pid};
    $quota = $$quotas1{"default"} unless exists $quotas{$pid};

    $usghrs = sprintf("%.3f", $usghrs);

    # Get nodes used by this experiment
	$num_nodes = $$pnodes{$pid};
	$num_nodes = 0 unless exists $$pnodes{$pid};
	$remaining = "N/A";
	if($num_nodes && $num_nodes != 0) {
	    if($usghrs < $quota) {
            $remaining = ($quota - $usghrs)/$num_nodes;
		    $remaining = sprintf("%.3f", $remaining);
	    }
		else {
            $remaining = 0; 
		}
	}

    local $/ = "\n";
	chomp $quota;
	print "$pid, $quota, $usghrs, $num_nodes, $remaining\n";
}
