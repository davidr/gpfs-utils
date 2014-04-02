#!/usr/bin/env perl

# The MIT License (MIT)
# 
# Copyright (c) 2014 David Ressman, davidr@ressman.org
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use vars;
use strict;
use Getopt::Long;
use Data::Dumper;
use POSIX qw/floor/;
use Expect;
#use Pod::Usage;
use autouse 'Pod::Usage' => qw(pod2usage);


### Begin Config ######################################################


my $mmfs_path = '/usr/lpp/mmfs/bin';

# debugging stuff:
my $DEBUG = 0;
$Expect::Debug = 0;
$Expect::Log_Stdout = 0;


### End Config ########################################################

my %options_hash;
my $rc = GetOptions ( \%options_hash, 'file|f=s', 'filesystem|s=s',
  'help|h', 'man');

pod2usage(1) if $options_hash{'help'};
pod2usage(-noperldoc => 0, -exitstatus => 0, -verbose => 2) if $options_hash{'man'};

if ((! $options_hash{'file'}) || (! -f  $options_hash{'file'})) {
    pod2usage("-f FILE is mandatory and FILE must be a regular file");
}

# Initialize the vars for the report
my ($f_inode, $f_filename, $f_size, $f_begin, $f_end, $f_nsd);

my $nsd_idhash = get_nsd_idhash($options_hash{'filesystem'});

# Locate the file's inode
#
my @stat_arr = stat($options_hash{'file'}) or die "$!: $options_hash{'file'}";
my $file_inode = $stat_arr[1];
my $file_size  = $stat_arr[7];

if ($DEBUG == 1) { print "inode: $file_inode\n";}
if ($DEBUG == 1) { print "size:  $file_size\n";}

# Get the filesystem's block size, so we know how many blocks this file is
# spread over.
#
my $fsblocksize = get_fsblocksize($options_hash{'filesystem'});
if (! $fsblocksize) {
    print STDERR
      "Couldn't retrieve GPFS block size for $options_hash{'filesystem'}\n";
    exit(1);
}

# We just need to know how many blocks in the file so we know how
# many times to iterate in tsdbfs.
#
my $div_result = $file_size / $fsblocksize;
my $num_iterations;

if (isint($div_result)) {
    $num_iterations = $div_result - 1;
} else {
    $num_iterations = floor($div_result);
}

my $inode_devarr = get_blocklist_from_inode( $options_hash{'filesystem'},
  $file_inode, $num_iterations);

$f_filename = $options_hash{'file'};
$f_size     = sprintf("%#x", $file_size) . " B";
$f_inode    = $file_inode;

$~ = 'REPORT';
$^ = 'REPORT_TOP';
$| = 1;
$= = 0x99999999;

my $start_block = 0;
foreach my $dev_string (@$inode_devarr) {

    my ($device, $sector) = split(/:/, $dev_string, 2);
    $f_nsd = "$nsd_idhash->{$device}:$sector";

    $f_begin = sprintf("%#x", $start_block);
    $f_end   = sprintf("%#x", $start_block + $fsblocksize - 1);

    write;

    $start_block += $fsblocksize;
}



#################################################################

sub get_nsd_idhash {
    my $fs = shift;
    my $nsd_idhash;

    open(MMLSDISK, '-|', "${mmfs_path}/mmlsdisk", $fs, '-i') or die $!;
    my $i = 0;

    while (<MMLSDISK>) {
        ++$i;
        next if $i < 4;

        my @split_arr = split(/\s+/, $_);
        $nsd_idhash->{$split_arr[8]} = $split_arr[0];
    }
    close MMLSDISK or die $!;

    return($nsd_idhash);
}

sub get_blocklist_from_inode {
    my $fs         = shift;
    my $inode      = shift;
    my $num_blocks = shift;

    # A reference to an array of the devices containing the blocks of
    # this file
    my $dev_list;

    my $expect_return;

    my $tsdbfs = new Expect();
    $tsdbfs->raw_pty(1);

    $tsdbfs->spawn("${mmfs_path}/tsdbfs", $fs);

    # Look for the initial strings so we know we opened the right program
    @{$expect_return} = $tsdbfs->expect(2, 'Type ? for help.');
    if ($expect_return->[1]) {
        print STERR "Did not get initial string from tsdbfs\n";
        return(undef);
    }

    # Ok, here goes!
    $tsdbfs->send("blockaddr $inode 0\n");

    @{$expect_return} = $tsdbfs->expect(5, '-re',
      'Inode [\d]+ snap [\d]+ offset 0 N=[\d]+ [\d]+:[\d]+');
    if ($expect_return->[1]) {
        print STERR "Did not get string back tsdbfs\n";
        return(undef);
    }

    # We have the string corresponding to the first block
    my $out_string = $expect_return->[2];
    if ($out_string =~ m/.* ([\d]+:[\d]+)$/) {
        push(@$dev_list, $1);
    }

    # Make sure we're accepting input again.
    @{$expect_return} = $tsdbfs->expect(30, '-re', 'Type \? for help.\n');
    if ($expect_return->[1]) {
        print STERR "Did not get initial string from tsdbfs\n";
        return(undef);
    }


    if ($num_blocks > 0) {
        $tsdbfs->send("iterate $num_blocks\n");
        # Make sure we're accepting input again.
        @{$expect_return} = $tsdbfs->expect(180, 'Enter command or null');
        if ($expect_return->[1]) {
            print STERR "Did not get initial string from tsdbfs\n";
            return(undef);
        }

        my $iterate_data_str = $expect_return->[3];
        chomp $iterate_data_str;

        my @iterate_data_arr = split(/\n/, $iterate_data_str);

        foreach my $block_data (@iterate_data_arr) {
            if ($block_data =~ /^Inode [\d]+.*[\s]+([\d]+:[\d]+)$/) {
                push(@$dev_list, $1);
            }
        }
    }

    $tsdbfs->send("quit\n");
    $tsdbfs->soft_close();

    return($dev_list);

}

sub get_fsblocksize {
    my $fs = shift();

    if (! open(MMLSFS, "-|", "${mmfs_path}/mmlsfs", ${fs}, '-B')) {
        print STDERR $!, "\n";
        return(undef);
    }

    while (<MMLSFS>) {
        chomp;

        # Look for the line containing the actual data
        #if ($_ =~ m/^[\s]*-B/) {
        #    $_ =~ s/^[\s]+//;
        #    my ($flag, $block_size, $cruft) = split(/[\s]+/);
	#    next if ($_ =~ m/system/);
	#
        #     # check to make sure the block size is actually a number
        #     if ($block_size =~ m/^[0-9]+$/) {
        #         close(MMLSFS) or die $!;
        #         return($block_size);
        #     }
        #}
	next if ($_ =~ m/system/);
	next if ($_ =~ m/^__+/);
	next if ($_ =~ m/^flag/);

        my ($flag, $block_size, $cruft) = split(/[\s]+/);
        # check to make sure the block size is actually a number
       	if ($block_size =~ m/^[0-9]+$/) {
        	close(MMLSFS) or die $!;
        	return($block_size);
       }
    }

    # We shouldn't be here. We should have returned with the block size
    # by now. Throw an error.
    close(MMLSFS) or die $!;
    return(undef);
}

sub get_blocklist {
    my $inode = shift();
    my $fs    = shift();
}

sub isint {
    my $num = shift;
    return ($num =~ m/^[\d]+$/);
}


format REPORT_TOP =

@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$f_filename
FS Block Size: @<<<<<<<<<<<<<<<      Inode: @<<<<<<<<<<<< Size: @<<<<<<<<<<<<<<<
$fsblocksize                                $f_inode            $f_size

    start offset - end offset                      NSD:sector
    (in bytes)     (in bytes)
--------------------------------------------------------------------------------

.

format REPORT =
@>>>>>>>>>>>>>>> - @<<<<<<<<<<<<<<< -------------- @<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$f_begin               $f_end                                    $f_nsd
.




__END__

=head1 NAME

gpfs_file2nsd - Given a filename, produce the list of NSDs on which
                that file's data resides.

=head1 SYNOPSIS

gpfs_file2nsd [options] [-f <filename>] [-s <filesystem>]

 Options:
   -h, --help                   brief help message
   --man                        display full documentation
   -f FILE                      full pathname of file to analyze
                                REQUIRED
   -s FILESYSTEM                gpfs filesystem name
                                REQUIRED

=head1 OPTIONS

=over 8

=item B<-h>, B<--help>

Print a brief help message and exit.

=item B<--man>

Print the full man page and exit.

=item B<-f FILE>

The full path of the file to be analyzed

=item B<-s FILESYSTEM>

The name of the GPFS filesystem on which the file resides. NOTE: This is the filesystem name as gpfs knows it, so it's not a pathname. 


=back

=cut

