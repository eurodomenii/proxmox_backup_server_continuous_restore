#!/usr/bin/perl

# by EuroDomenii - MIT -  2020
# Prereq:
# apt install jq

use strict;
use warnings;

use Expect;
use Acme::Comment type => 'C++';

use POSIX qw(strftime);

use File::Basename;
my $dirname = dirname(__FILE__);

use Fcntl qw(:flock);
open my $file, ">", "$dirname/app.lock" or die $!;
flock $file, LOCK_EX|LOCK_NB or die "Unable to lock file $!";
# we have the lock

my @par = @ARGV;
my $repository = "";
my $password = "";
my $prefix = "";

for (my $i = 0; $i <= $#par; ++$i) {
    local $_ = $par[$i];
    if (/--password/){
        $password = $par[++$i];
        next;
    }
    if (/--repository/) {
        $repository = $par[++$i];
        next;
    }
    if (/--prefix/) {
        $prefix = $par[++$i];
        next;
    }
}

if ($repository eq "") {
    print q(Please setup --repository parameter. Format sample: "myuser@pbs@localhost:store2");
    print "\n";
    exit;
}

if ($password eq "") {
    print q(Please setup --password parameter. Use single quotes for password to avoid exclamation mark issues in bash parameters. Format sample:  --password 'Zrs$#bVn1aQKLgzA6Lc0OJTB#RMSR**qZ6!MO9KKY');
    print "\n";
    exit;
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

$ENV{PBS_REPOSITORY} = $repository;
$ENV{PBS_PASSWORD} = $password;

#Credits https://www.perlmonks.org/?node_id=786670
system("proxmox-backup-client login");
#for testing run proxmox-backup-client logout --repository $repository

my @vmids = `proxmox-backup-client snapshots --output-format=json-pretty | jq '.[] | ."backup-id"'`;
my @filtered = uniq(@vmids);

foreach my $i (@filtered) {
    chomp $i;
    #Remove quotes
    my $id = substr $i, 1,-1;
    my $first_digit = substr($id, 0, 1);
    if ( $prefix ne "" and $prefix ne $first_digit ) {
        next;
    }

    my @timestamps = `proxmox-backup-client snapshots --output-format=json-pretty | jq -r '.[] | select(."backup-id" == $i) | ."backup-time"'`;
    my @sorted = sort @timestamps;
    my $latest = pop @sorted;

    my $backup_type = `proxmox-backup-client snapshots --output-format=json-pretty | jq -r '.[] | select(."backup-id" == $i and ."backup-time" == $latest) | ."backup-type"'`;
    chomp $backup_type;

    my $datestring = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime($latest);
    #ToDo FeatureRequest: It would be helpful if the output format json-pretty would provide out of the box a snapshot field like text format, in order to avoid reconstruction
    my $snapshot = "$backup_type/$id/$datestring";

    #Instead of working with pvesh get /nodes/{node}/qemu/{vmid}, let's go at cluster level
    my $status = `pvesh get /cluster/resources --output-format=json-pretty | jq -r '.[] | select(.vmid == $id) | .status'`;
    chomp $status;
    my (undef, $storage) = split(':\s*', $repository);

    if( $backup_type  eq  "vm" ) {
        #ToDo Before stopping / destroying the VM, it would be better to restore to another id. In case that production server goes down and the restoring process is too long on the standby server, there would be the option to go online with a previous restored VM. For the moment is low priority, due to the burden of keeping track of the correlation between different stages of restore, for the same VM.
        if ($status eq "running") {
            #play safer with stop instead shutdown. Anyway, next step is destroy, so it doesn't matter consistency.
            system("qm stop $id --skiplock true");
        }
        if ($status ne "") {
            system("qm destroy $id --skiplock true --purge true");
        }

        #https://forum.proxmox.com/threads/pbs-restore-proxmox-kvm-from-cli.73163/#post-327076
        #no need to test running restore task via "proxmox-backup-client task list", anyway it restores sequentially
        my $qmrestore = `qmrestore --force true $storage:backup/$snapshot $id`;

        printf "Restoring VM id $id from snapshot $snapshot on storage $storage\n";
        system("qm start $id --skiplock true");
        printf "Starting VM id $id \n";

    } elsif( $backup_type  eq  "ct" ) {
        if ($status eq "running") {
            system("pct stop $id --skiplock true");
        }
        if ($status ne "") {
            system("pct destroy $id --force true --purge true");
        }

        my $lxcrestore = `pct restore --force true --unprivileged true $id $storage:backup/$snapshot`;

        printf "Restoring Container id $id from snapshot $snapshot on storage $storage\n";
        system("pct start $id --skiplock true");
        printf "Starting Container id $id \n";
    } else {
        printf "Skipping... incorect backup type $backup_type\n";
    }

}
