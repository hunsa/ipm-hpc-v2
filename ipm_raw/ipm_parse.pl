#!/usr/bin/perl 
#use strict;
use POSIX;
use File::Basename;
use FileHandle;
use Data::Dumper;

use feature say;

#graph format
$gfmt = "png";

#
#
# This is a parser for IPM logfiles. It can generate human 
# readable reports from the markup in IPM logfiles. Three report
# formats are implmented:
# 
# terse: the default output to stdout from IPM at execution time
# full: the output from IPM with IPM_REPORT=full
# html: make a directory with index.html and graphics
# json: convert the XML file to JSON
#
# David Skinner (NERSC/LBL)
# Dec 2004 dskinner@nersc.gov
# Dec 2011 dskinner@nersc.gov (JSON)
#

# config

#$IPM_KEYFILE="/home/dskinner/src/ipm/ipm_key";
$IPM_KEYFILE=$ENV{"IPM_KEYFILE"};

chomp($PLOTICUS_BIN=`which pl`);

if(! -x $PLOTICUS_BIN ) {
 print "Can't find ploticus (pl).\n"; exit(0);
}

#$PLOTICUS_BIN="/usr/local/bin/pl";
#$PLOTICUS_BIN="/usr/common/usg/ploticus/2.31/bin/pl";
#$PLOTICUS_BIN="/usr/common/nsg/bin/pl";


$PLOTICUS_FLAGS= " -maxproclines 1000000 -maxfields 10000000 -maxvector 1000000 -maxrows 1000000";
$PLOTICUS= $PLOTICUS_BIN." ".$PLOTICUS_FLAGS;
$PLOTICUS_PREFABS="/www/ploticus/src/prefabs/";


#unless(-e $IPM_KEYFILE) {
# print "can't find MPI keyfile. exiting.\n".
# exit(1);
#}

$OOGB = 1.0/(1024*1024*1024);

STDOUT->autoflush(1);

$SPLIT_COLLECTIVE = 0;
%mpi_call = ();
sub numy { $a <=> $b }
sub byidv { $a{idv} <=> $b{idv} }
open(FH,"< $IPM_KEYFILE");
while(defined($line = <FH>)) {
 chomp($line);
 @v = split('\|',$line);
 $_ = $v[2];
 /(.*) (.*)\((.*)\)/;
 $id = $2;
 next if ($SPLIT_COLLECTIVE == 0 && $line =~ "MPE_I");
 @u = split('\,',$v[4]);
 $mpi_call_name{$v[0]} = $id;
 $mpi_call{$id} = {
  idv => "$v[0]",
  idl => "$v[1]",
  cpt => "$v[2]",
  fpt => "$v[3]",
  sem => "$u[0]",
  byt => "$u[1]",
  rnk => "$u[2]",
  dat => "$u[3]"};
}
close(FH);

#foreach $call (sort byidv keys %mpi_call) {
# print "$call - $mpi_call{$call}{idl} - $mpi_call{$call}{dat}\n";
#}


# center : repo : job : region : task : {*}

#
# organization of data structures:
#
# JOB: $jobs is the top level, keyed by cookies, composed of tasks
#      the parser may read in multiple jobs at once.
#
# TASK: describes the unix process for each mpi rank and it'
#       each task has regions (1 by default) and has gbyte, data_tx, data_rx
#       outermost tag in the log since each task does it's own IPM and logging
#
# REGION: each region has counters and funcs (region does not have gbyte)
#         a region other than ipm_global corresponds to the programatic 
#         context contained within a MPI_Pcontrol(1->-1) block
#
# HENT: a hash entry is the most detailed default description of an MPI
#       call or other event. A hent has call, size, rank, region
#
# all of the above have wtime, utime, stime, mtime, iotime
#
# FUNC: has a function label (name) and call count and wall time spent in field
#
# COUNTER: has a label and a count. This is often a HPM counter
#
# TRACE: is a func + counters + timestamp (not used by default)
#
# LABEL: is an integer and a text string (call site or function name)
#        labels avoid repeating text strings in the log 
#
#
# a cookie uniquely identifies a job
#
# a job:
#	 $J = \%{$jobs{$cookie}}
#
# examples of info about a job
# 	$J->{wtime|utime|stime|mtime|iotime|pop|gflop|nhosts|ntasks|hostname}
#
# examples of info about a region in a job (aggregated across tasks)
# 	$J->{region}{wtime|utime|stime|iotime|mtime|pop|gflop}
#
# a task 
# 	$T = \%{$jobs{$cookie}{task}{$mpi_rank}} == $J->{task}{$mpi_rank}
#
# examples of info about a task 
# 	$T->{hostname|cmdline|cmdline_base|exec|exec_bin|mach_info|gbyte|gflop}
#       $T->{pid|wtime|utime|stime|mtime|iotime|mpi_size|pcomm|flags|switch}
#       $T->{nregion|username|groupname}
#
# a region
# $R = \%{$jobs{$cookie}{task}{$mpi_rank}{region}{region_a}}; --> region_a of a task
# so e.g.,
# $T->{mtime} is the MPI time for that task. 
# $R->{mtime} is the MPI time in region_a for that task
#
# Aggregation tasks care of mapping the $R to $T to $J values
# 


%flags = ();
$njobs = 0;
$ijob = 0;
%jobs = ();
$global_ipm_version = "NULL";
$region_current = "parse_none";
@rusage_label = ("utime", "stime", "maxrss", "ixrss", "idrss", "isrss", "minflt", "majflt", "nswap", "inblock", "oublock", "msgsnd", "msgrecv", "nsignals", "nvcsw", "nivcsw");

@ipm_color=   (	"red", "green", "blue", "yellow", 
               	"purple","coral", "orange", "darkblue", "limegreen",
               	"skyblue","claret", "teal", "magenta", "brightblue",
		"black", "lightpurple", "kelleygreen", "yellowgreen",
		"redorange", "darkblue", "tan1", "drabgreen",
		"yellow2", "teal", "lavender",
		"rgb(0.0,1.0,1.0)","rgb(0.8,0.8,0.8)",
               	"rgb(0.7,0.7,0.7)","rgb(0.6,0.6,0.6)",
		"rgb(0.5,0.5,0.5)", "rgb(0.2,0.2,0.2)");

%ipm_color_bycall = ();

sub taskbyrank  { $a <=> $b }; 
sub regbywtime { $J->{region}{$a}{wtime} <=> $J->{region}{$b}{wtime} };
sub jfuncbytime { $J->{func}{$a}{time} <=> $J->{func}{$b}{time} };
sub jrfuncbytime { $JR->{func}{$a}{time} <=> $JR->{func}{$b}{time} };
sub taskbymtime { $J->{task}{$a}{mtime} <=> $J->{task}{$b}{mtime} };
sub taskbyiotime { $J->{task}{$a}{iotime} <=> $J->{task}{$b}{iotime} };
sub hostbyswitch { $J->{host}{$a}{gbyte_s} <=> $J->{host}{$b}{gbyte_s} };
sub hostbymem { $J->{host}{$a}{gbyte} <=> $J->{host}{$b}{gbyte} };
sub taskbygflop { $J->{task}{$a}{gflop} <=> $J->{task}{$b}{gflop} };
sub taskbyneigh { $J->{mpi}{neigh}{$a} <=> $J->{mpi}{neigh}{$b} };
sub jcallbyttot { $J->{mpi}{call}{$a}{ttot} <=> $J->{mpi}{call}{$b}{ttot} };
sub jfuncbyttot { $J->{func}{$a}{time} <=> $J->{func}{$b}{time} };
sub jcallsizebyttot { $J->{mpi}{call_size}{$a}{ttot} <=> $J->{mpi}{call_size}{$b}{ttot} };
sub circbydata {$circ{$a}{byte} <=> $circ{$b}{byte}};
sub circbynmsg {$circ{$a}{nmsg} <=> $circ{$b}{nmsg}};

$DEBUG                  =(1<<  0);
$VERBOSE                =(1<<  1);
$REPORT_TERSE           =(1<<  2);
$REPORT_FULL            =(1<<  4);
$REPORT_NONE            =(1<<  5);
$REPORT_LABELIO         =(1<<  6);
$IPM_INITIALIZED        =(1<< 10);
$IPM_PASSTHRU           =(1<< 11);
$IPM_ABORTED            =(1<< 12);
$IPM_INTERRUPTED        =(1<< 13);
$IPM_FINALIZED          =(1<< 14);
$IPM_MPI_INITIALIZED    =(1<< 15);
$IPM_MPI_REGIONALIZED   =(1<< 16);
$IPM_MPI_FINALIZING     =(1<< 17);
$IPM_MPI_FINALIZED      =(1<< 18);
$IPM_MPI_INSIDE         =(1<< 19);
$IPM_MPI_ACTIVE         =(1<< 20);
$IPM_MPI_CANCELED       =(1<< 21);
$IPM_HPM_ACTIVE         =(1<< 22);
$IPM_HPM_CANCELED       =(1<< 23);
$IPM_APP_RUNNING        =(1<< 24);
$IPM_APP_COMPLETED      =(1<< 25);
$IPM_APP_INTERRUPTED    =(1<< 26);
$IPM_WROTESYSLOG        =(1<< 27);
$IPM_TRC_ACTIVE         =(1<< 30);
$IPM_TRC_CANCELED       =(1<< 31);


sub usage {
 print "\n";
 print "usage: IPM parse [-full|-html|-i|-t] [-x] [-debug]  file [files] \n";
 print "\n";
 print "\t -full \t region, hpm, and MPI breakouts \n";
 print "\t -html \t generate HTML in a subdir  \n";
 print "\t -sql \t generate SQL summary (rohan schema)\n";
 print "\t -i \t basic info about the file, one line per file\n";
 print "\t -p \t performance info about the file, one line per file\n";
 print "\t -mpi \t dump the hash table MPI data one line per entry\n";
 print "\t -w \t workload info about the file, one line per file\n";
 print "\t -x \t linearly interoplate an incomplete file\n";
 print "\t -e \t describe the entropy in the hash table\n";
 print "\t -k key\t decode int64 key\n";
 print "\n";
 print "\t by default a terse ouput in banner form is generated\n";
 print "\n";
}


if(@ARGV == 0 || $ARGV[0] =~ /^-h$/ || $ARGV[0] =~ /^-help$/) {
 usage();
 exit(1);
}

####
#  Parse ARGV
####

%flags = ();
$flags{report_terse} = 1;
$flags{report_full} = 0;
$flags{report_html} = 0;
$flags{report_hash_mpi} = 0;
$flags{report_dot} = 0;
$flags{debug} = 0;
$flags{devel} = 0;
$flags{clean} = 0;

my $topology_tasks=1025;

$not_fname = 1;
while($not_fname) {
 if($ARGV[0] =~ /^-debug$/) {
  $flags{debug} = 1;
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-x$/) {
  $flags{extrapolate} = 1;
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-full$/) {
  $flags{report_terse} = 0; 
  $flags{report_full} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-mpi$/) {
  $flags{report_terse} = 0; 
  $flags{report_hash_mpi} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-dot$/) {
  $flags{report_terse} = 0; 
  $flags{report_dot} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-w$/) {
  $flags{report_terse} = 0; 
  $flags{report_wload} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-html$/) {
  $flags{report_terse} = 0; 
  $flags{report_html} = 1; 
  shift @ARGV;
  unless(-e $PLOTICUS_BIN) {
   print "can't find ploticus \"$PLOTICUS_BIN\" (needed for HTML). exiting.\n";
   exit(1);
  }
 } elsif($ARGV[0] =~ /^-i$/) {
  $flags{report_terse} = 0; 
  $flags{info_only} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-t$/) {
  $flags{report_terse} = 0; 
  $flags{trace_only} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-devel$/) {
  $flags{report_terse} = 0; 
  $flags{report_html} = 1; 
  $flags{report_devel} = 1; 
  shift @ARGV;
 } elsif($ARGV[0] =~ /^-k$/) {
  shift @ARGV;
  $flags{key_decode} = 1;
  $key_decode = floor($ARGV[0]);
} elsif($ARGV[0] =~ /^-force-topology$/){
  $topology_tasks=1000000;
  shift @ARGV;
} elsif($ARGV[0] =~ /^-json$/){
  $flags{report_terse} = 0; 
  $flags{report_json} = 1; 
  shift @ARGV;
 } else {
  $not_fname = 0;
 }
}

if($flags{debug}) {
 foreach $k (sort keys %flags) {
	 print "IPM parse:  FLAG $k = $flags{$k}\n";
 }
}

####
#  Key decode only {
####
 if($flags{key_decode}) {
  @bits = split(//, unpack("b64", 1*$key_decode));
  foreach $bit (@bits) {
   print "$bit";
  }
  print "\n"; 
  exit(0);
 }
####
#  end Key decode only }
####

 $TINT1 = time();
####
#  Acquisition {
####

$done = 0;
while(!$done) {
 $fname = shift @ARGV;
 $got_version = 0;
 if($flags{debug}) { print "IPM parse:  file = $fname $#ARGV\n";}

 if(defined($flags{trace_only})) {
  print "#rank t1 t2 call buffer region orank {hpm1} {hpm2}\n";
  open(FH, "< $fname") or die "Couldn't read from file: $fname\n";
  $do_print = 0;
  while(defined($line = <FH>)) {
   if($line =~ /^<trace (.*)>/) {
    if($flags{debug}) { print "IPM trace: task $1\n"; } 
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $$key = $value;
    }
    print "# $line"; $do_print = 1; next;
   }
   if($line =~ /^<\/trace (.*)>/) {
    print "# $line"; $do_print = 0; next;
   }
   if($do_print == 1) { 
    chomp($line);
    ($t1, $call1, $byte1, $oreg1, $orank1, $hpm1) =  split(" ",$line,6);
    $do_print = 2; next;
   }
   if($do_print == 2) { 
    chomp($line);
    ($t2, $call2, $byte2, $oreg2, $orank2, $hpm2) =  split(" ",$line,6);
    print "$mpi_rank $t1 $t2 $mpi_call_name{$call1} $byte1 $oreg1 $orank1 $hpm1 $hpm2\n";
    $do_print = 1;
   }
  }
  close(FH);
  exit;
 }

 if(defined($flags{info_only})) {
  open(FH, "< $fname") or die "Couldn't read from file: $fname\n";
  $got_ver = 0;
  while($got_ver == 0 && defined($line = <FH>)) {
   if($line =~ /^<task (.*)>/) {
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $$key = $value;
    }
   }
   if($line =~ /<cmdline (.*)>(.*)<\/cmdline>/) {
    $rpath = $1;
    print "$fname IPMv$ipm_version $mpi_size $rpath\n";
    $got_ver = 1;
   }
  }
  close(FH);
 } else  {


 open(FH, "< $fname") or die "Couldn't read from file: $fname\n";


 while(defined($line = <FH>)) {
 
 if($flags{debug}) { print "IPM parse:  line $line</line> \n";}

  if($line =~ /^<task ipm_version="([0-9.]+)" (.*)$/) {
   $iversion = $1;
   if($global_ipm_version =~ /^NULL$/) {
    $global_ipm_version = $iversion;
   }
   unless($iversion =~ /^$global_ipm_version$/) {
    print "IPM: parse error, multiple versions \"$iversion\" and \"$global_ipm_iversion\" in input\n";
    exit(1);
   }
   $region_index = 0;
  }


  $got_version = 0;
  if($iversion =~ "0.8[56789]" || $iversion =~ "0.[89][0-9][0-9]" || $iversion =~ "2.0.[0-9]") {
   $got_version = 1;
   if($line =~ /^<task (.*)>/) {
    if($flags{debug}) { print "IPM parse: task $1\n"; } 
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $$key = $value;
    }
    if($flags{debug} == 1) {
     print "task $ipm_version $cookie $mpi_rank $mpi_size $stamp_init $stamp_final $username $flags\n";
    }


    $jobs{$cookie}{ipm_version} = $ipm_version;


    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     if($key !~ "cookie" && $key !~ "mpi_rank") {
      if(defined($jobs{$cookie}{task}{$mpi_rank}{$key})) {
       print "IPM parse: ERROR corrupted input (duplicate task entry?) $cookie:$mpi_rank:$key \n";
      }
      $jobs{$cookie}{task}{$mpi_rank}{$key} = $value;
     }
    }
   $T = \%{$jobs{$cookie}{task}{$mpi_rank}};
   $J = \%{$jobs{$cookie}};
   if(!defined($J->{ntasks_got})) {
    $J->{ntasks_got} = 1;
   } else {
    $J->{ntasks_got} ++;
   }
   if($J->{ntasks_got}%100==0) {print "$J->{ntasks_got}.."; }
  }


   if($line =~ /^<job (.*)>(.*)<\/job>/) {
    $jobs{$cookie}{id} = $2;
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $jobs{$cookie}{$key} = $value;
    }
    $jobs{$cookie}{filename} = $fname;
    $jobs{$cookie}{filename_base} = basename($fname);
   }

   if($line =~ /^<host (.*)>(.*)<\/host>/) {
    if($flags{debug}) { print "IPM parse: host $1 $2\n"; }
    $T->{hostname} = $2;
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $T->{$key} = $value;
    }
   }

   if($line =~ /<perf (.*)><\/perf>/) {
    if($flags{debug}) { print "IPM parse: perf $1\n";}
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $T->{$key} = $value;
    }
    if($T->{wtime} <= 0.0) {
     if($flags{debug}) { print "IPM parse: ERROR wtime <= 0 $1\n";}
    }
    $T->{gflop} *= 1.0;
#    print "perf $mpi_rank $T->{gflop}\n";
   }

   if($line =~ /<switch (.*)>(.*)<\/switch>/) {
    if($flags{debug}) { print "IPM parse: switch $1\n";}
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $T->{$key} = $value;
    }
# FIXME - deal with plurals in a consistent way : debug hash typo can be hard
    $T->{byte_tx} = $T->{bytes_tx};
    $T->{byte_rx} = $T->{bytes_rx};
    $T->{switch} = $2;
   }

   $J->{env} = "";
   if($line =~ /<env>(.*)<\/env>/) {
    $J->{env} = $J->{env}."\n".$1;
   }

   if($line =~ /<cmdline (.*)>(.*)<\/cmdline>/) {
    if($flags{debug}) { print "IPM parse: cmdline $2\n";}
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $T->{$key} = $value;
    }
    $T->{cmdline} = $2;
    $T->{cmdline_base} = basename($T->{realpath});
   }


   if($line =~ /<exec><pre>/) {
    while(defined ($line = <FH>) && !($line =~ /<\/pre><\/exec>/)) {
     $T->{exec}  .= $line;
    }
    if($flags{debug}) { print "IPM parse: exec $T->{exec}\n";}
   }

   if($line =~ /<exec_bin><pre>/) {
    while(defined ($line = <FH>) && !($line =~ /<\/pre><\/exec_bin>/)) {
     $T->{exec_bin}  .= $line;
    }
    if($flags{debug}) { print "IPM parse: exec $T->{exec_bin}\n";}
   }

   if($line =~ /<ru_(\w+)>(.*)<\/ru_(\w+)>/) {
    if($flags{debug}) { print "IPM parse: ru_$1 $2\n";}
    $ru_tag = "ru_".$1;
    @vp = ();
    @vp = split(" ",$2);
    $i = 0;
    foreach $v (@vp) {
     if(!defined($rusage_label[$i])) {
      print "$v - $i whoa ".@rusage_label." - $rusage_label[$i]\n";
     }
     $key = $ru_tag."_".$rusage_label[$i];
     $T->{$key} = $v;
     $i++;
    }
   }

   if($line =~ /<regions n="(\d+)" >/) {
    if($flags{debug}) { print "IPM parse: regions $1\n";}
    $T->{nregion} = $1;
   }

   if($line =~ /<region label="(\S+)" (.*)>/) {
    $tag = $1;
    $rest = $2;

# fix for version 0.85 -> 0.86 log file changes
    $rest =~ s/" wall="/" wtime="/;
    $rest =~ s/" user="/" utime="/;
    $rest =~ s/" sys="/" stime="/;
    $rest =~ s/" mpi="/" mtime="/;

# fix for utime" typo in v0.86
    $rest =~ s/" utime"/" utime="/;

    if($flags{debug}) { print "IPM parse: region label=$tag , $rest\n";}
    if($region_current !~ "parse_none") {
     print "IPM parse: ERROR region $tag started prior to $region_current closing.\n";
     exit(1);
    }
    $region_current = $tag;
    $region_current =~ s/ /_/g;

    $R=\%{$T->{region}{$region_current}};
    if(!defined($J->{region_index}{$region_index})) {
     $J->{region_index}{$region_index} = $region_current;
     $region_index ++;
    }
    @vp = split("\" ",$rest);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $R->{$key} = $value;
    }
    if(!defined($R->{wtime})) {
     print "IPM: Parse error in $ireg $irank (no wtime)\n";
    }
#    print "region $region_current $R->{nexits} $R->{wtime} $R->{utime} $R->{stime} $R->{mtime}\n";
   }

 
   if($line =~ /<func name="(.*)" count="(.*)" > (.*) <\/func>/) {
    if($flags{debug}) { print "IPM parse: func $1\n";}
    $R->{func}{$1}{count} = $2;
    $R->{func}{$1}{time} = $3;
   }

   if($line =~ /<hash (.*) >/) {
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $T->{hash_diag}{$key} = $value;
    }
   }

   if($line =~ /<module name="MPI" time="(.*)" ><\/module>/) {
    $T->{mod_mpi_time} = $1;
   }

   if($line =~ /<module name="POSIXIO" time="(.*)" ><\/module>/) {
    $T->{iotime} = $1;
   }

   if($line =~ /<hent (.*) >(.*) (.*) (.*)<\/hent>/) {
    $attr = $1;
    $ittot = $2;
    $itmin = $3;
    $itmax = $4;
    $ikey_last = -1;
    @vp = split("\" ",$attr);
    foreach $kv (@vp) {
     ($k, $v) = split("=\"",$kv);
     $v =~ s/\"//g;
     if($k =~ /^key$/) {$ikey = $v;}
     if($k =~ /^key_last$/) {$ikey_last = $v;}
     if($k =~ /^call$/) {$icall = $v;}
     if($k =~ /^bytes$/) {$ibyte = $v;}
     if($k =~ /^orank$/) {$iorank = $v;}
     if($k =~ /^region$/) {$ireg = $J->{region_index}{$v}; $iregion=$v;}
     if($k =~ /^count$/) {$icount = $v;}
    }

    unless($icall =~ /MPI_/) {
     print "ERROR non-MPI hent (icall = $icall) $line";
    }

    if($flags{report_dot}) {
     if($ikey_last < 0) { print "ERROR no key history in report_dot\n"; exit(1);    }

     if(!defined($J->{graph}{node}{$ikey}{byte})) {
      $J->{graph}{node}{$ikey}{call} = $icall;
      $J->{graph}{node}{$ikey}{byte} = $ibyte;
      $J->{graph}{node}{$ikey}{ttot} = $ittot;
      $J->{graph}{node}{$ikey}{tmin} = $itmin;
      $J->{graph}{node}{$ikey}{tmax} = $itmax;
      $J->{graph}{node}{$ikey}{tmin_r} = $irank;
      $J->{graph}{node}{$ikey}{tmax_r} = $irank;
      $J->{graph}{node}{$ikey}{count} = $icount;
      $J->{graph}{node}{$ikey}{region} = $iregion;
      $J->{graph}{edge}{$ikey}{$ikey_last} = 1;
     } else {
      $J->{graph}{node}{$ikey}{time} += $ittot;
      $J->{graph}{node}{$ikey}{count} += $icount;
      if($itmin < $J->{graph}{node}{$ikey}{tmin}) {
       $J->{graph}{node}{$ikey}{tmin} = $itmin;
       $J->{graph}{node}{$ikey}{tmin_r} = $irank;
      }
      if($itmax < $J->{graph}{node}{$ikey}{tmax}) {
       $J->{graph}{node}{$ikey}{tmax} = $itmax;
       $J->{graph}{node}{$ikey}{tmax_r} = $irank;
      }
      $J->{graph}{node}{$ikey}{count} ++;
      $J->{graph}{node}{$ikey}{region} = $iregion;
      $J->{graph}{edge}{$ikey}{$ikey_last} ++;
     }
    }

    if($flags{report_hash_mpi}) {
     print "$ikey $ikey_last $mpi_rank $icall $ibyte $mpi_rank $iorank $ireg $icount $ittot $itmin $itmax\n";
    }



# save memory by not storing whole hash for large core counts
# does not mitigate againist MPI codes with large numbers of entries in the hash 
# but relatively small core counts. These are rare though.
#
    if ($J->{ntasks} <= $topology_tasks ) {
	$J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{count} = $icount;
	$J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{ttot} = $ittot;
	$J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{tmin} = $itmin;
	$J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{tmax} = $itmax;
    }

    if ($flags{report_html} || $flags{report_wload}) {
       if (!defined($J->{mpi}{call}{$icall}{ttot})) {$J->{mpi}{call}{$icall}{ttot}=0.0};
       if (!defined($J->{mpi}{call}{$icall}{count})) {$J->{mpi}{call}{$icall}{count}=0};
       if (!defined($T->{mpi}{call}{$icall}{ttot})) {$T->{mpi}{call}{$icall}{ttot}=0.0};
       $cskey = $icall."!".$ibyte;
       $T = \%{$J->{task}{$mpi_rank}};
       $JR = \%{$J->{region}{$ireg}};
       $TR = \%{$T->{region}{$ireg}};
       $irank=$mpi_rank;
       $J->{mpi}{time}{$irank}{$iorank} +=$ittot;
       $JR->{mpi}{time}{$irank}{$iorank} +=$ittot;

       if($mpi_call{$icall}{dat} =~ /^DATA_TX$/ ||
	  $mpi_call{$icall}{dat} =~ /^DATA_TXRX$/) {
	   $J->{mpi}{nmsg_tx}{$irank}{$iorank} +=$icount;
	   $J->{mpi}{data_tx}{$irank}{$iorank} +=$icount*$ibyte;
	   $J->{mpi}{time_tx}{$irank}{$iorank} +=$ittot;
	   
	   $JR->{mpi}{nmsg_tx}{$irank}{$iorank} +=$icount;
	   $JR->{mpi}{data_tx}{$irank}{$iorank} +=$icount*$ibyte;
	   $JR->{mpi}{time_tx}{$irank}{$iorank} +=$ittot;
 
	   $TR->{mpi}{nmsg_tx}{$irank}{$iorank} +=$icount;
	   $TR->{mpi}{data_tx}{$irank}{$iorank} +=$icount*$ibyte;
	   $TR->{mpi}{time_tx}{$irank}{$iorank} +=$itot;
#print "data_tx $irank $iorank $icall $ibyte \n";
       }

       if($mpi_call{$icall}{dat} =~ /^DATA_RX$/ ||
	  $mpi_call{$icall}{dat} =~ /^DATA_TXRX$/) {
	   $J->{mpi}{nmsg_rx}{$irank}{$iorank} +=$icount;
	   $J->{mpi}{data_rx}{$irank}{$iorank} +=$icount*$ibyte;
# avoid double count since time only happens once for TXRX
	   unless($mpi_call{$icall}{dat} =~ /^DATA_TXRX$/) {
	       $J->{mpi}{time_rx}{$irank}{$iorank} +=$itot;
	   }
 
	   $JR->{mpi}{nmsg_rx}{$irank}{$iorank} +=$icount;
	   $JR->{mpi}{data_rx}{$irank}{$iorank} +=$icount*$ibyte;
# avoid double count since time only happens once for TXRX
	   unless($mpi_call{$icall}{dat} =~ /^DATA_TXRX$/) {
	       $JR->{mpi}{time_rx}{$irank}{$iorank} +=$ittot;
	   }

	   $TR->{mpi}{nmsg_rx}{$irank}{$iorank} +=$icount;
	   $TR->{mpi}{data_rx}{$irank}{$iorank} +=$icount*$ibyte;
# avoid double count since time only happens once for TXRX
	   unless($mpi_call{$icall}{dat} =~ /^DATA_TXRX$/) {
	       $TR->{mpi}{time_rx}{$irank}{$iorank} +=$ittot;
	   }
#print "data_rx $irank $iorank $icall $ibyte \n";
       }

# joint call_size (also store min, max, minrank, maxrank for each call_size)
 
       if(!defined($J->{mpi}{call_size}{$cskey}{count})) {
	   $J->{mpi}{call_size}{$cskey}{count} = 0;
	   $J->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	   $J->{mpi}{call_size}{$cskey}{tmax} = $itmax;
       }
       if(!defined($JR->{mpi}{call_size}{$cskey}{count})) {
	   $JR->{mpi}{call_size}{$cskey}{count} = 0;
	   $JR->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	   $JR->{mpi}{call_size}{$cskey}{tmax} = $itmax;
       }
       if(!defined($T->{mpi}{call_size}{$cskey}{count})) {
	   $T->{mpi}{call_size}{$cskey}{count} = 0;
	   $T->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	   $T->{mpi}{call_size}{$cskey}{tmax} = $itmax;
       }
       if(!defined($TR->{mpi}{call_size}{$cskey}{count})) {
	   $TR->{mpi}{call_size}{$cskey}{count} = 0;
	   $TR->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	   $TR->{mpi}{call_size}{$cskey}{tmax} = $itmax;
       }

##
# counts and totals
##
       $J->{mpi}{call_size}{$cskey}{count} += $icount;
       $JR->{mpi}{call_size}{$cskey}{count} += $icount;
       $TR->{mpi}{call_size}{$cskey}{count} += $icount;
 
       $J->{mpi}{call_size}{$cskey}{ttot} += $ittot;
       $JR->{mpi}{call_size}{$cskey}{ttot} += $ittot;
       $TR->{mpi}{call_size}{$cskey}{ttot} += $ittot;
##
# min/max
##
      if($itmax > $J->{mpi}{call_size}{$cskey}{tmax}) {
	  $J->{mpi}{call_size}{$cskey}{tmax} = $itmax;
	  $J->{mpi}{call_size}{$cskey}{tmax_r} = $irank;
      }
 
      if($ittmin < $J->{mpi}{call_size}{$cskey}{tmin}) {
	  $J->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	  $J->{mpi}{call_size}{$cskey}{tmin_r} = $irank;
      }


      if($itmax > $JR->{mpi}{call_size}{$cskey}{tmax}) {
	  $JR->{mpi}{call_size}{$cskey}{tmax} = $itmax;
	  $JR->{mpi}{call_size}{$cskey}{tmax_r} = $irank;
      }
 
      if($itmin < $JR->{mpi}{call_size}{$cskey}{tmin}) {
	  $JR->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	  $JR->{mpi}{call_size}{$cskey}{tmin_r} = $irank;
      }


      if($itmax > $TR->{mpi}{call_size}{$cskey}{tmax}) {
	  $TR->{mpi}{call_size}{$cskey}{tmax} = $itmax;
	  $TR->{mpi}{call_size}{$cskey}{tmax_r} = $irank;
      }
 
      if($itmin < $TR->{mpi}{call_size}{$cskey}{tmin}) {
	  $TR->{mpi}{call_size}{$cskey}{tmin} = $itmin;
	  $TR->{mpi}{call_size}{$cskey}{tmin_r} = $irank;
      }
 
##
# J overall
##
       $J->{mpi}{call}{$icall}{ttot} += $ittot;
       $J->{mpi}{call}{$icall}{count} += $icount;
##
# JR overall
##
       $JR->{mpi}{call}{$icall}{ttot} += $ittot;
       $JR->{mpi}{call}{$icall}{count} += $icount;
# T specific
 
       $T->{mpi}{call}{$icall}{ttot} += $ittot;
       $T->{mpi}{call}{$icall}{count} += $icount;
 
# TR specific
 
      $TR->{mpi}{call}{$icall}{ttot} += $ittot;
      $TR->{mpi}{call}{$icall}{count} += $icount;
 
#      print "$icall $ibyte $irank $iorank $ireg $J->{hash}{$icall}{$ibyte}{$irank}{$iorank}{$ireg}{ttot}\n";


   }

   }


# the hents were processed as below before 0.910 when IPM_ENABLE_KEYHIST
# required adding one more attribute to <hent>. The above is more general
# anyway but may break parsers that assume a fixed attr list. e.g., we have
# to rename the variables to \i* to match the names in this perl code

   if(0 && $line =~ /<hent key="(.*)" call="(.*)" byte="(.*)" orank="(.*)" region="(.*)" count="(.*)" >(.*) (.*) (.*)<\/hent>/) {
    if($flags{debug}) { print "IPM parse: hent $1\n";}
    $ikey = $1;
    $icall = $2;
    $ibyte = $3;
    $iorank = $4;
    $ireg = $J->{region_index}{$5};
    $icount = $6;
    $ittot = $7;
    $itmin = $8;
    $itmax = $9;

    unless($icall =~ /MPI_/) {
     print "ERROR $line";
    }

    if($flags{report_hash_mpi}) {
     print "$ikey $ikey_last $mpi_rank $icall $ibyte $mpi_rank $iorank $ireg $icount $ittot $itmin $itmax\n";
    }

    $J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{count} = $icount;
    $J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{ttot} = $ittot;
    $J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{tmin} = $itmin;
    $J->{hash}{$icall}{$ibyte}{$mpi_rank}{$iorank}{$ireg}{tmax} = $itmax;
   }

   if($line =~ /<hpm api="(\S+)" ncounter="(\S+)" eventset="(\S+)" gflop="(\S+)" >/)  {
    $api = $1;
    $ncounter = $2;
    $eventset = $3;
    $gflop = $4;
    $R->{gflop} = 1.0*$gflop;
#    print "perf $mpi_rank $T->{gflop} $gflop\n";
   }

   if($line =~ /<counter name="(.*)" > (.*) <\/counter>/) {
    $icounter = $1;
    $icount = $2;
#    print "counter $icounter $mpi_rank $icount\n";
    $R->{counter}{$icounter}{count} = $icount;
   }

   if($line =~ /<\/region>$/) {
    $region_current = "parse_none";
    $T->{nregion_got}++;
   }

   if($line =~ /<internal (.*)>/) {
    @vp = split("\" ",$1);
    foreach $kv (@vp) {
     ($key, $value) = split("=\"",$kv);
     $value =~ s/\"//;
     $T->{$key} = $value;
    }
   }

  }

  if($iversion == "0.9") {
  }

 }
 close(FH);
 
  if($got_version == 0) {
   print "Unrecognized IPM version($global_ipm_version)in file $fname (skipped)\n";
  }

 }
 if($#ARGV < 0) {$done=1;}
}


if($flags{debug}) { 
foreach $cookie ( sort keys %jobs ) {
 foreach $jkey ( sort keys %{$jobs{$cookie}} ) {
  if($jkey =~ "ipm_version") {
    print "IPM dump: j{$cookie}{ipm_version} $jobs{$cookie}{ipm_version} \n";
  }

  if($jkey =~ "task") {
   foreach $mpi_rank (sort keys %{$jobs{$cookie}{task}} ) {
    foreach $key (sort keys %{$jobs{$cookie}{task}{$mpi_rank}} ) {
     print "IPM parse: dump j{$cookie}{task}{$mpi_rank}{$key} $jobs{$cookie}{task}{$mpi_rank}{$key} $jobs{$cookie}{task}{$mpi_rank}{$key} $jobs{$cookie}{task}{$mpi_rank}{$key}\n";
    }
   }
  }


 }
}
}


####
#  End data acquisition }
####

 $TINT2 = time();

 if($J->{ntasks_got} > 100) {
  print "\n"; # close the 100..200.300.. line if needed 
 }


if(defined($flags{info_only})) {
 exit;
}

foreach $cookie (sort keys %jobs) {
 $J = \%{$jobs{$cookie}};

####
#  Error Checking and Extrapolation
####

 $ntask_min=0;
 foreach $irank (sort keys %{$J->{task}} ) {
  $ntask_min  = $J->{task}{$irank}{mpi_size};
 }
 
 if($J->{ntasks_got} <  $ntask_min ) {
  if($flags{extrapolate}) {

# find the first "good" task 

   for($irank=0;$irank < $J->{ntasks}; $irank++) {
    $T = $J->{task}{$irank};
    if(defined($T)) {
     $TLAST= $T;
     next;
    }
   }

# copy the last "good" task to fill any gap

   for($irank=0;$irank < $J->{ntasks}; $irank++) {
    $T = $J->{task}{$irank};
    if(defined($T)) {
     $T = $TLAST;
    } else {
     $TLAST = $T;
    }
   }

  } else {
   print "IPM parse: ERROR incomplete jobdata, $J->{ntasks_got} of  $J->{ntasks} tasks found. \n";
   print "IPM parse: consider using the '-x' parsing option\n";
   exit(1);
  }

 }

####
#  Aggregation {
####

 $J->{ntasks_aggregated} = 0;

 foreach $irank (sort keys %{$J->{task}} ) {
 $T = \%{$J->{task}{$irank}};

  if($J->{ntasks_aggregated} == 0) { # first task
   $J->{username} = $T->{username};
   $J->{groupname} = $T->{groupname};
   $J->{cmdline} = $T->{cmdline};
   $J->{ntasks} = $T->{mpi_size};
   $J->{hostname} = $T->{hostname};
   $J->{flags} = $T->{flags};
   $J->{mach_info} = $T->{mach_info};
   $J->{cmdline_base} = $T->{cmdline_base};
   $J->{wtime_min} = $J->{wtime_max}= $T->{wtime};
   $J->{utime_min} = $J->{utime_max}= $T->{utime};
   $J->{stime_min} = $J->{stime_max}= $T->{stime};
   $J->{mtime_min} = $J->{mtime_max}= $T->{mtime};
   $J->{iotime_min} = $J->{iotime_max}= $T->{iotime};
   $J->{gflop_min} = $J->{gflop_max}= $T->{gflop};
   $J->{gbyte_min} = $J->{gbyte_max}= $T->{gbyte};
$J->{wtime_minr} = $J->{utime_minr} = $J->{stime_minr} = $J->{mtime_minr} = $J->{iotime_minr} = $irank;
$J->{wtime_maxr} = $J->{utime_maxr} = $J->{stime_maxr} = $J->{mtime_maxr} =$J->{iotime_minr}= $irank;
   $J->{wtime} = $J->{utime} = $J->{stime} = $J->{mtime} = $J{iotime} = 0 ;
   $J->{gflop} = $J->{gbyte} =  0;
   $J->{byte_tx} = $J->{byte_rx} = 0;
   $J->{byte_tx_min} = $J->{byte_tx_max}= $T->{byte_tx};
   $J->{byte_rx_min} = $J->{byte_rx_max}= $T->{byte_rx};
   $J->{ntasks_aggregated} = 0;
  }

###
# {host} {
###

   $ihost = $T->{hostname};
   if(!defined ($J->{host}{$ihost})) {
    $J->{host}{$ihost}{gbyte_s} = 0.0;
    $J->{host}{$ihost}{gbyte_tx} = 0.0;
    $J->{host}{$ihost}{gbyte_rx} = 0.0;
    $J->{host}{$ihost}{gbyte} = 0.0;
    $J->{host}{$ihost}{gflop} = 0.0;
    $J->{host}{$ihost}{wtime} = 0.0;
    $J->{host}{$ihost}{utime} = 0.0;
    $J->{host}{$ihost}{stime} = 0.0;
    $J->{host}{$ihost}{mtime} = 0.0;
    $J->{host}{$ihost}{iotime} = 0.0;
   }

    $J->{host}{$ihost}{gbyte_tx} += $T->{byte_tx}*$OOGB;
    $J->{host}{$ihost}{gbyte_rx} += $T->{byte_rx}*$OOGB;
    $J->{host}{$ihost}{gbyte_s} += ($T->{byte_tx}+$T->{byte_rx})*$OOGB;
    $J->{host}{$ihost}{gbyte} += $T->{gbyte};
    $J->{host}{$ihost}{gflop} += $T->{gflop};
    $J->{host}{$ihost}{wtime} += $T->{wtime};
    $J->{host}{$ihost}{utime} += $T->{utime};
    $J->{host}{$ihost}{stime} += $T->{stime};
    $J->{host}{$ihost}{mtime} += $T->{mtime};
    $J->{host}{$ihost}{iotime} += $T->{iotime};
   
###
# {host} }
###

   $J->{ntasks_aggregated} ++;
   $J->{wtime} += $T->{wtime};
   $J->{utime} += $T->{utime};
   $J->{stime} += $T->{stime};
   $J->{mtime} += $T->{mtime};
   $J->{mod_mpi_time} += $T->{mod_mpi_time};
   $J->{iotime} += $T->{iotime};
   $J->{gbyte} += $T->{gbyte};
   $J->{gflop} += $T->{gflop};
   $J->{byte_tx} += $T->{byte_tx};
   $J->{byte_rx} += $T->{byte_rx};
  

   $J{hostlist}{$T->{hostname}}{$irank} += 1;

###
# Across regions
###

if($T->{gflop} > $J->{gflop_max}) { $J->{gflop_max} = $T->{gflop}; $J->{gflop_maxr} = $irank; }
if($T->{byte_tx} > $J->{byte_tx_max}) { $J->{byte_tx_max} = $T->{byte_tx}; $J->{byte_tx_maxr} = $irank }
if($T->{byte_rx} > $J->{byte_rx_max}) { $J->{byte_rx_max} = $T->{byte_rx}; $J->{byte_rx_maxr} = $irank; }
if($T->{gbyte} > $J->{gbyte_max}) { $J->{gbyte_max} = $T->{gbyte}; $J->{gbyte_maxr} = $irank; }
if($T->{wtime} > $J->{wtime_max}) { $J->{wtime_max} = $T->{wtime}; $J->{wtime_maxr} = $irank; }
if($T->{utime} > $J->{utime_max}) { $J->{utime_max} = $T->{utime}; $J->{utime_maxr} = $irank; }
if($T->{stime} > $J->{stime_max}) { $J->{stime_max} = $T->{stime}; $J->{stime_maxr} = $irank; }
if($T->{mtime} > $J->{mtime_max}) { $J->{mtime_max} = $T->{mtime}; $J->{mtime_maxr} = $irank; }
if($T->{iotime} > $J->{iotime_max}) { $J->{iotime_max} = $T->{iotime}; $J->{iotime_maxr} = $irank; }
  
if($T->{gflop} < $J->{gflop_min}) { $J->{gflop_min} = $T->{gflop}; $J->{gflop_minr} = $irank; }
if($T->{byte_tx} < $J->{byte_tx_min}) { $J->{byte_tx_min} = $T->{byte_tx};$J->{byte_tx_minr} = $irank; }
if($T->{byte_rx} < $J->{byte_rx_min}) { $J->{byte_rx_min} = $T->{byte_rx};$J->{byte_rx_minr} = $irank; }
if($T->{gbyte} < $J->{gbyte_min}) { $J->{gbyte_min} = $T->{gbyte}; $J->{gbyte_minr} = $irank; }
if($T->{wtime} < $J->{wtime_min}) { $J->{wtime_min} = $T->{wtime}; $J->{wtime_minr} = $irank; }
if($T->{utime} < $J->{utime_min}) { $J->{utime_min} = $T->{utime}; $J->{utime_minr} = $irank; }
if($T->{stime} < $J->{stime_min}) { $J->{stime_min} = $T->{stime}; $J->{stime_minr} = $irank; }
if($T->{mtime} < $J->{mtime_min}) { $J->{mtime_min} = $T->{mtime}; $J->{mtime_minr} = $irank; }
if($T->{iotime} < $J->{iotime_min}) { $J->{iotime_min} = $T->{iotime}; $J->{iotime_minr} = $irank; }
  
##
# Among regions
##

  foreach $ireg (sort keys %{$T->{region}} ) {
   $TR = \%{$T->{region}{$ireg}};
   $JR = \%{$J->{region}{$ireg}};

   if(!defined($JR->{ntasks})) {
    $JR->{ntasks} = 1;
    $JR->{nexits} =  $JR->{nexits_min} =  $JR->{nexits_max} = $TR->{nexits};
    $JR->{nexits_minr} =  $JR->{nexits_maxr} = $irank;
    $JR->{wtime} = $JR->{wtime_min} = $JR->{wtime_max} = $TR->{wtime};
    $JR->{utime} = $JR->{utime_min} = $JR->{utime_max} = $TR->{utime};
    $JR->{stime} = $JR->{stime_min} = $JR->{stime_max} = $TR->{stime};
    $JR->{mtime} = $JR->{mtime_min} = $JR->{mtime_max} = $TR->{mtime};
    $JR->{iotime} = $JR->{iotime_min} = $JR->{iotime_max} = $TR->{iotime};
    $JR->{gflop} = $JR->{gflop_min} = $JR->{gflop_max} = $TR->{gflop};
    foreach $icounter (sort keys %{$TR->{counter}}) {
     $JR->{counter}{$icounter}{count} = $TR->{counter}{$icounter}{count};
     $JR->{counter}{$icounter}{count_min} = $TR->{counter}{$icounter}{count};
     $JR->{counter}{$icounter}{count_max} = $TR->{counter}{$icounter}{count};
     $JR->{counter}{$icounter}{count_minr} =  $irank;
     $JR->{counter}{$icounter}{count_maxr} =  $irank;
    }
   } else { # we've seen this $ireg region before (in another task) 

   $JR->{ntasks}++;
   $JR->{nexits} += $TR->{nexits};
   if($TR->{nexits} > $JR->{nexits_max}) {
    $JR->{nexits_max} = $TR->{nexits};
    $JR->{nexits_maxr} = $irank;;
   }
   if($TR->{nexits} < $JR->{nexits_min}) {
    $JR->{nexits_min} = $TR->{nexits};
    $JR->{nexits_minr} = $irank;;
   }
   
   $JR->{wtime} += $TR->{wtime};
   $JR->{utime} += $TR->{utime};
   $JR->{stime} += $TR->{stime};
   $JR->{mtime} += $TR->{mtime};
   $JR->{iotime} += $TR->{iotime};
   $JR->{gflop} += $TR->{gflop};
#   print "debug $ireg $JR->{gflop} $TR->{gflop} $JR->{ntasks}\n";
   foreach $icounter (sort keys %{$TR->{counter}}) {
    $JR->{counter}{$icounter}{count} += $TR->{counter}{$icounter}{count};
   }

if($TR->{gflop} > $JR->{gflop_max}) { $JR->{gflop_max} = $TR->{gflop}; }
if($TR->{wtime} > $JR->{wtime_max}) { $JR->{wtime_max} = $TR->{wtime}; }
if($TR->{utime} > $JR->{utime_max}) { $JR->{utime_max} = $TR->{utime}; }
if($TR->{stime} > $JR->{stime_max}) { $JR->{stime_max} = $TR->{stime}; }
if($TR->{mtime} > $JR->{mtime_max}) { $JR->{mtime_max} = $TR->{mtime}; }
if($TR->{iotime} > $JR->{iotime_max}) { $JR->{iotime_max} = $TR->{iotime}; }
foreach $icounter (sort keys %{$TR->{counter}}) {
 if($TR->{counter}{$icounter}{count} > $JR->{counter}{$icounter}{count_max}) {
  $JR->{counter}{$icounter}{count_max} = $TR->{counter}{$icounter}{count};
  $JR->{counter}{$icounter}{count_maxr} = $irank;
 }
}

if($TR->{gflop} < $JR->{gflop_min}) { $JR->{gflop_min} = $TR->{gflop}; }
if($TR->{wtime} < $JR->{wtime_min}) { $JR->{wtime_min} = $TR->{wtime}; }
if($TR->{utime} < $JR->{utime_min}) { $JR->{utime_min} = $TR->{utime}; }
if($TR->{stime} < $JR->{stime_min}) { $JR->{stime_min} = $TR->{stime}; }
if($TR->{mtime} < $JR->{mtime_min}) { $JR->{mtime_min} = $TR->{mtime}; }
if($TR->{iotime} < $JR->{iotime_min}) { $JR->{iotime_min} = $TR->{iotime}; }
foreach $icounter (sort keys %{$TR->{counter}}) {
  if($TR->{counter}{$icounter}{count} < $JR->{counter}{$icounter}{count_min}) {
   $JR->{counter}{$icounter}{count_min} = $TR->{counter}{$icounter}{count};
   $JR->{counter}{$icounter}{count_minr} = $irank;
  }
 }
}


  foreach $ifunc (sort keys %{$TR->{func}}) {

##
# stats between tasks : "Which task had the most MPI_Barrier in region X?"
##
   if(!defined($JR->{func}{$ifunc})) {
    $JR->{func}{$ifunc}{count} = $TR->{func}{$ifunc}{count};
#    print "$ireg $ifunc $irank $JR->{func}{$ifunc}{count} = $TR->{func}{$ifunc}{count}\n";
    $JR->{func}{$ifunc}{count_min} = $TR->{func}{$ifunc}{count};
    $JR->{func}{$ifunc}{count_minr} = $irank;
    $JR->{func}{$ifunc}{count_max} = $TR->{func}{$ifunc}{count};
    $JR->{func}{$ifunc}{count_maxr} = $irank;
    $JR->{func}{$ifunc}{time} = $TR->{func}{$ifunc}{time};
    $JR->{func}{$ifunc}{time_min} = $TR->{func}{$ifunc}{time};
    $JR->{func}{$ifunc}{time_minr} = $irank;
    $JR->{func}{$ifunc}{time_max} = $TR->{func}{$ifunc}{time};
    $JR->{func}{$ifunc}{time_maxr} = $irank;
   } else {
#    print "$ireg $ifunc $irank $JR->{func}{$ifunc}{count} += $TR->{func}{$ifunc}{count}\n";
    $JR->{func}{$ifunc}{count} += $TR->{func}{$ifunc}{count};
    $JR->{func}{$ifunc}{time} += $TR->{func}{$ifunc}{time};
    if($TR->{func}{$ifunc}{count} < $JR->{func}{$ifunc}{count_min}) {
     $JR->{func}{$ifunc}{count_min} = $TR->{func}{$ifunc}{count};
     $JR->{func}{$ifunc}{count_minr} = $irank;
    }
    if($TR->{func}{$ifunc}{count} > $JR->{func}{$ifunc}{count_max}) {
     $JR->{func}{$ifunc}{count_max} = $TR->{func}{$ifunc}{count};
     $JR->{func}{$ifunc}{count_maxr} = $irank;
    }
    if($TR->{func}{$ifunc}{time} < $JR->{func}{$ifunc}{time_min}) {
     $JR->{func}{$ifunc}{time_min} = $TR->{func}{$ifunc}{time};
     $JR->{func}{$ifunc}{time_minr} = $irank;
    }
    if($TR->{func}{$ifunc}{time} > $JR->{func}{$ifunc}{time_max}) {
     $JR->{func}{$ifunc}{time_max} = $TR->{func}{$ifunc}{time};
     $JR->{func}{$ifunc}{time_maxr} = $irank;
    }
   }
  }
  } # ~$TR ~$JR
 } # ~$T ~$irank

####
#  Derivation : $irank is now out of scope for first pass
####

####
#  Derivation : back through regions
####
   ##
   # stats across tasks : "How much MPI_barrier time in the whole job?"
   # (since func is a sub tag of region we get this only by summation across
   # both regions _and_ tasks). Likewise we can't answer "Which task had 
   # the most MPI_Barrier time until now since we had only regional info.
   # maybe this would be less twisted if we put a <func> tags outside the 
   # context of any region, but this bloats the log file. 
   #
   # avoid stats below since "which region had the min/max X?" is uninteresting
   ##

 foreach $irank (sort keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  foreach $ireg (sort keys %{$T->{region}} ) {
   $TR = \%{$T->{region}{$ireg}};
   $JR = \%{$J->{region}{$ireg}};

   foreach $icounter (sort keys %{$TR->{counter}}) {
    if(!defined($T->{counter}{$icounter}{count})) {
     $T->{counter}{$icounter}{count} = $TR->{counter}{$icounter}{count};
    } else {
     $T->{counter}{$icounter}{count} += $TR->{counter}{$icounter}{count};
    }
   }

   foreach $ifunc (sort keys %{$TR->{func}}) {

    if(!defined($T->{func}{$ifunc})) {
     $T->{func}{$ifunc}{count} = $TR->{func}{$ifunc}{count};
     $T->{func}{$ifunc}{time} = $TR->{func}{$ifunc}{time};
    } else {
     $T->{func}{$ifunc}{count} += $TR->{func}{$ifunc}{count};
     $T->{func}{$ifunc}{time} += $TR->{func}{$ifunc}{time};
    }

   }
  }
 }

###
# Now we have the <func> tags independent of region per task
###

 foreach $irank (sort keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  foreach $icounter (sort keys %{$T->{counter}}) {
   if(!defined($J->{counter}{$icounter}{count})) {
    $J->{counter}{$icounter}{count} = $T->{counter}{$icounter}{count};
    $J->{counter}{$icounter}{count_min} = $T->{counter}{$icounter}{count};
    $J->{counter}{$icounter}{count_max} = $T->{counter}{$icounter}{count};
    $J->{counter}{$icounter}{count_minr} = $irank; 
    $J->{counter}{$icounter}{count_maxr} = $irank;
   } else {
    $J->{counter}{$icounter}{count} += $T->{counter}{$icounter}{count}; 
    if($T->{counter}{$icounter}{count} > $J->{counter}{$icounter}{count_max}) {
     $J->{counter}{$icounter}{count_max} = $T->{counter}{$icounter}{count};
     $J->{counter}{$icounter}{count_maxr} = $irank;
    }
    if($T->{counter}{$icounter}{count} < $J->{counter}{$icounter}{count_min}) {
     $J->{counter}{$icounter}{count_min} = $T->{counter}{$icounter}{count};
     $J->{counter}{$icounter}{count_minr} = $irank;
    }
   }
  }

  $T->{ipmrate} = 0.0;
  foreach $ifunc (sort keys %{$T->{func}}) {
   $T->{ipmrate} += $T->{func}{$ifunc}{count};
   if(!defined($J->{func}{$ifunc})) {
     $J->{func}{$ifunc}{count} = $T->{func}{$ifunc}{count};
     $J->{func}{$ifunc}{count_min} = $T->{func}{$ifunc}{count};
     $J->{func}{$ifunc}{count_minr} = $irank;
     $J->{func}{$ifunc}{count_max} = $T->{func}{$ifunc}{count};
     $J->{func}{$ifunc}{count_maxr} = $irank;
     $J->{func}{$ifunc}{time} = $T->{func}{$ifunc}{time};
     $J->{func}{$ifunc}{time_min} = $T->{func}{$ifunc}{time};
     $J->{func}{$ifunc}{time_minr} = $irank;
     $J->{func}{$ifunc}{time_max} = $T->{func}{$ifunc}{time};
     $J->{func}{$ifunc}{time_maxr} = $irank;
   } else {
    $J->{func}{$ifunc}{count} += $T->{func}{$ifunc}{count};
    $J->{func}{$ifunc}{time} += $T->{func}{$ifunc}{time};
    if($T->{func}{$ifunc}{count} < $J->{func}{$ifunc}{count_min}) {
     $J->{func}{$ifunc}{count_min} = $T->{func}{$ifunc}{count};
     $J->{func}{$ifunc}{count_minr} = $irank;
    }
    if($T->{func}{$ifunc}{count} < $J->{func}{$ifunc}{count_max}) {
     $J->{func}{$ifunc}{count_max} = $T->{func}{$ifunc}{count};
     $J->{func}{$ifunc}{count_maxr} = $irank;
    }
    if($T->{func}{$ifunc}{time} < $J->{func}{$ifunc}{time_min}) {
     $J->{func}{$ifunc}{time_min} = $T->{func}{$ifunc}{time};
     $J->{func}{$ifunc}{time_minr} = $irank;
    }
    if($T->{func}{$ifunc}{time} < $J->{func}{$ifunc}{time_max}) {
     $J->{func}{$ifunc}{time_max} = $T->{func}{$ifunc}{time};
     $J->{func}{$ifunc}{time_maxr} = $irank;
    }
   }

  }
  $T->{ipmrate} /= $T->{wtime};
 }

###
# Now we have the <func> tags independent of region for the whole job.  
###



####
#  Derivation : global
####

 $J->{jtime} = $J->{wtime_max};
# $J->{gflops} = int(100000*($J->{gflop}/$J->{jtime}))/100000.0;
# $J->{gflops_min} = int(100000*($J->{gflop_min}/$J->{jtime}))/100000.0;
# $J->{gflops_max} = int(100000*($J->{gflop_max}/$J->{jtime}))/100000.0;
 $J->{gflops} = ($J->{gflop}/$J->{jtime});
 $J->{gflops_min} = ($J->{gflop_min}/$J->{jtime});
 $J->{gflops_max} = ($J->{gflop_max}/$J->{jtime});
 $J->{pcomm} = 100*$J->{mtime}/($J->{ntasks}*$J->{jtime});
 $J->{pio} = 100*$J->{iotime}/($J->{ntasks}*$J->{jtime});
 $J->{nregion} = 0;

# Initialization 

 foreach $irank (sort keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  $T->{pcomm} = 100*$T->{mtime}/$T->{wtime};
  $T->{pio} = 100*$T->{iotime}/$T->{wtime};
  foreach $ireg (sort keys %{$T->{region}} ) {
   if(!defined($J->{region_name}{$ireg})) {
    $J->{region_name}{$ireg} = $ireg;
    $J->{nregion} ++;
   }
   $TR = \%{$T->{region}{$ireg}};
   $JR = \%{$J->{region}{$ireg}};
   $TR->{pcomm} = 100*$TR->{mtime}/$TR->{wtime};
   $TR->{pio} = 100*$TR->{iotime}/$TR->{wtime};
  }
  foreach $icounter (sort keys %{$T->{counter}} ) {
   $J->{counter}{$icounter}{pop} = 0;
   $JR->{counter}{$icounter}{pop} = 0;
  }
 }


# Scan over tasks then regions {

 foreach $irank (sort keys %{$J->{task}} ) {
 $T = \%{$J->{task}{$irank}};
 if(!defined($J->{pcomm_max})) {
  $J->{pcomm_max} = $J->{pcomm_min} = $T->{pcomm};
  $J->{pcomm_maxr} = $J->{pcomm_minr} = $irank;
 } else {
if($T->{pcomm} < $J->{pcomm_min}) { $J->{pcomm_min} = $T->{pcomm}; }
if($T->{pcomm} > $J->{pcomm_max}) { $J->{pcomm_max} = $T->{pcomm}; }
 }

 foreach $icounter (sort keys %{$T->{counter}} ) {
  $J->{counter}{$icounter}{pop} ++;
 }

  foreach $ireg (sort keys %{$T->{region}} ) {
   $TR = \%{$T->{region}{$ireg}};
   $JR = \%{$J->{region}{$ireg}};
   foreach $icounter (sort keys %{$T->{counter}} ) {
    $JR->{counter}{$icounter}{pop} ++;
   }
 if(!defined($JR->{pcomm_max})) {
  $JR->{pcomm_max} = $JR->{pcomm_min} = $TR->{pcomm};
  $JR->{pcomm_maxr} = $JR->{pcomm_minr} = $irank;
 } else {
if($TR->{pcomm} < $JR->{pcomm_min}) { $JR->{pcomm_min} = $TR->{pcomm}; }
if($TR->{pcomm} > $JR->{pcomm_max}) { $JR->{pcomm_max} = $TR->{pcomm}; }
 }

  }

 }

# End scan over tasks then regions }

foreach $ireg (sort keys %{$J->{region}} ) {
  $JR = \%{$J->{region}{$ireg}};
  $JR->{pcomm} = 100*$JR->{mtime}/$JR->{wtime};
  $JR->{pio} = 100*$JR->{iotime}/$JR->{wtime};
  $JR->{gflops} = int(100000*($JR->{gflop}/$JR->{wtime}))/100000.0;
  $JR->{gflops_min} = int(100000*($JR->{gflop_min}/$JR->{wtime}))/100000.0;
  $JR->{gflops_max} = int(100000*($JR->{gflop_max}/$JR->{wtime}))/100000.0;
}

# foreach $icounter (sort keys %{$J->{counter}} ) {
#  print "counter $icounter $J->{counter}{$icounter}{count}\n";
# }
 

 $J->{gbyte_tx} = $J->{byte_tx}/(1024.0*1024*1024.0);
 $J->{gbyte_rx} = $J->{byte_rx}/(1024.0*1024*1024.0);
 $J->{gbyte_tx_min} = $J->{byte_tx_min}/(1024.0*1024*1024.0);
 $J->{gbyte_tx_max} = $J->{byte_tx_max}/(1024.0*1024*1024.0);
 $J->{gbyte_rx_min} = $J->{byte_rx_min}/(1024.0*1024*1024.0);
 $J->{gbyte_rx_max} = $J->{byte_rx_max}/(1024.0*1024*1024.0);
 

 if($J->{flags} & $IPM_APP_RUNNING) {
  $J->{app_state} = "running";
 } elsif($J->{flags} & $IPM_APP_INTERRUPTED) {
  $J->{app_state} = "interrupted";
 } elsif($J->{flags} & $IPM_APP_COMPLETED) {
  $J->{app_state} = "completed";
 } else {
  $J->{app_state} = "unknown";
 }

 $J->{start_date_buf} = strftime("%m/%d/%y/%T", localtime($J->{start}));
 $J->{final_date_buf} = strftime("%m/%d/%y/%T", localtime($J->{final}));

####
#  Aggregation (END) }
####

####
#  Report Generation  {
####

$FLT_REP_FMT="# %-20.20s %13g %13g %13g %13g\n";
$PCT_REP_FMT="# %-20.20s               %13g %13g %13g\n";
$MPI_REP_FMT="# %-20.20s %13g %13g        %6.2f       %6.2f\n";


 if($flags{report_dot}) {
  print "digraph app {\n";
  print "graph [splines=true, overlap=false];\n";
  print "//neato  -Tsvg -o dot.svg dot\n";
  foreach $ikey (keys %{$J->{graph}{node}}) {
   $JN = \%{ $J->{graph}{node}{$ikey} };
   $icall = $JN->{call};
   $ibyte = $JN->{byte};
   $ireg = $JN->{region};
   $ittot = $JN->{ttot};
   $itmin = $JN->{tmin};
   $itmax = $JN->{tmax};
   if(!defined($J->{dot}{node}{$icall}{$ibyte}{$ireg}{ttot})) {
    $J->{dot}{node}{$icall}{$ibyte}{$ireg}{ttot} = $ittot;
    $J->{dot}{node}{$icall}{$ibyte}{$ireg}{name} = $icall.".".$ibyte.".".$ireg;
   } else {
    $J->{dot}{node}{$icall}{$ibyte}{$ireg}{ttot} += $ittot;
   }
  }

  foreach $icall (keys %{$J->{dot}{node}}) {
  foreach $ibyte (keys %{$J->{dot}{node}{$icall}}) {
  foreach $ireg (keys %{$J->{dot}{node}{$icall}{$ibyte}}) {
   $JN = \%{ $J->{dot}{node}{$icall}{$ibyte}{$ireg} };
   $h = $w = $JN->{ttot};
   printf "\"%s\" [shape=circle height=%f, width=%f];\n", $JN->{name}, $w , $w;
  }
  }
  }

  foreach $ikey (keys %{$J->{graph}{edge}}) {
    $JN = \%{ $J->{graph}{node}{$ikey} };
    $icall = $JN->{call};
    $ibyte = $JN->{byte};
    $ireg = $JN->{region};
    $iname =  $J->{dot}{node}{$icall}{$ibyte}{$ireg}{name};
   foreach $iokey (keys %{$J->{graph}{edge}{$ikey}}) {
    if($iokey != 1) { # no edge to the 1 key which is the start of the history
    $JON = \%{ $J->{graph}{node}{$iokey} };
    $iocall = $JON->{call};
    $iobyte = $JON->{byte};
    $ioreg = $JON->{region};
    $ioname =  $J->{dot}{node}{$iocall}{$iobyte}{$ioreg}{name};
    $w = $J->{graph}{edge}{$ikey}{$iokey};
    print "\"$iname\" -> \"$ioname\" [dir=back, weight=$w];\n";
    }
   }
  }

  print "}\n";

 }

 if($flags{report_terse} || $flags{report_full}) {
 printf("##IPMv%s#####################################################################\n",$global_ipm_version);
 printf("# \n");
 printf("# command : %s (%s)\n", $J->{cmdline}, $J->{app_state});
 printf("# host    : %-30s mpi_tasks : %d on %d nodes\n",
	 $J->{hostname}, 
	 $J->{ntasks},
	 $J->{nhosts});
 printf("# start   : %17s              wallclock : %f sec\n",
         $J->{start_date_buf}, $J->{jtime});
 printf("# stop    : %17s              %%comm     : %-.2f \n",
         $J->{final_date_buf}, $J->{pcomm});
# if(flags & IPM_HPM_CANCELED)  deal with this
 printf("# gbytes  : %.5e total              gflop/sec : %.5e total\n",
        $J->{gbyte}, 
        $J->{gflop}/$J->{jtime});

 printf("#\n");

 if($flags{report_full}) {  ### Full


  printf("#                           [total]         <avg>           min           max\n");
   printf("$FLT_REP_FMT","wallclock",
	$J->{wtime},
	$J->{wtime}/$J->{ntasks},
	$J->{wtime_min},
	$J->{wtime_max});

   printf("$FLT_REP_FMT","user",
	$J->{utime},
	$J->{utime}/$J->{ntasks},
	$J->{utime_min},
	$J->{utime_max});

   printf("$FLT_REP_FMT","system",
	$J->{stime},
	$J->{stime}/$J->{ntasks},
	$J->{stime_min},
	$J->{stime_max});

   printf("$FLT_REP_FMT","mpi",
	$J->{mtime},
	$J->{mtime}/$J->{ntasks},
	$J->{mtime_min},
	$J->{mtime_max});

   printf("$PCT_REP_FMT","%comm",
	$J->{pcomm},
	$J->{pcomm_min},
	$J->{pcomm_max});

   printf("$FLT_REP_FMT","gflop/sec",
	$J->{gflops},
	$J->{gflops}/$J->{ntasks},
	$J->{gflops_min},
	$J->{gflops_max});

   printf("$FLT_REP_FMT","gbytes",
	$J->{gbyte},
	$J->{gbyte}/$J->{ntasks},
	$J->{gbyte_min},
	$J->{gbyte_max});

   if($J->{gbyte_tx_min} > 0) {
   printf("$FLT_REP_FMT","gbytes_tx",
	$J->{gbyte_tx},
	$J->{gbyte_tx}/$J->{ntasks},
	$J->{gbyte_tx_min},
	$J->{gbyte_tx_max});
   }

   if($J->{gbyte_rx_min} > 0) {
   printf("$FLT_REP_FMT","gbyte_rx",
	$J->{gbyte_rx},
	$J->{gbyte_rx}/$J->{ntasks},
	$J->{gbyte_rx_min},
	$J->{gbyte_rx_max});
   }

  printf("#\n");

foreach $icounter (sort keys %{$J->{counter}}) {
   printf("$FLT_REP_FMT","$icounter",
	$J->{counter}{$icounter}{count},
	$J->{counter}{$icounter}{count}/$J->{ntasks},
	$J->{counter}{$icounter}{count_min},
	$J->{counter}{$icounter}{count_max});
}

  printf("#\n"); 
  $header = 0;
  foreach $ifunc (reverse(sort jfuncbytime keys %{$J->{func}})) { 
  if($header==0) { printf("#                            [time]       [calls]        <%%mpi>      <%%wall>\n"); $header = 1;};
   if(100*$J->{func}{$ifunc}{time}/$J->{mtime} > 0.01){ 
   printf("$MPI_REP_FMT", $ifunc, 
	$J->{func}{$ifunc}{time}, 
	$J->{func}{$ifunc}{count}, 
	100*$J->{func}{$ifunc}{time}/$J->{mtime}, 
	100*$J->{func}{$ifunc}{time}/($J->{ntasks}*$J->{jtime}));
   }
  }

 foreach $ireg (reverse (sort regbywtime keys %{$J->{region}} )) {
  $JR = \%{$J->{region}{$ireg}};

  printf("###############################################################################\n");
  printf("# region : %s        [ntasks] = %d\n#\n", $ireg,$JR->{ntasks});
  printf("#                           [total]         <avg>           min           max\n");
   printf("$FLT_REP_FMT","entries",
	$JR->{nexits},
	$JR->{nexits}/$JR->{ntasks},
	$JR->{nexits_min},
	$JR->{nexits_max});

   printf("$FLT_REP_FMT","wallclock",
	$JR->{wtime},
	$JR->{wtime}/$JR->{ntasks},
	$JR->{wtime_min},
	$JR->{wtime_max});

   printf("$FLT_REP_FMT","user",
	$JR->{utime},
	$JR->{utime}/$JR->{ntasks},
	$JR->{utime_min},
	$JR->{utime_max});

   printf("$FLT_REP_FMT","system",
	$JR->{stime},
	$JR->{stime}/$JR->{ntasks},
	$JR->{stime_min},
	$JR->{stime_max});

   printf("$FLT_REP_FMT","mpi",
	$JR->{mtime},
	$JR->{mtime}/$J->{ntasks},
	$JR->{mtime_min},
	$JR->{mtime_max});

   printf("$PCT_REP_FMT","%comm",
	$JR->{pcomm},
	$JR->{pcomm_min},
	$JR->{pcomm_max});

   printf("$FLT_REP_FMT","gflop/sec",
	$JR->{gflops},
	$JR->{gflops}/$JR->{ntasks},
	$JR->{gflops_min},
	$JR->{gflops_max});

  printf("#\n");

foreach $icounter (sort keys %{$JR->{counter}}) {
   printf("$FLT_REP_FMT","$icounter",
	$JR->{counter}{$icounter}{count},
	$JR->{counter}{$icounter}{count}/$JR->{ntasks},
	$JR->{counter}{$icounter}{count_min},
	$JR->{counter}{$icounter}{count_max});
}

  printf("#\n");

  $header = 0;
  foreach $ifunc (reverse(sort jrfuncbytime keys %{$JR->{func}})) { 
  if($header == 0 ) {
  printf("#                            [time]       [calls]        <%%mpi>      <%%wall>\n");
   $header = 1;
  }
   if(100*$JR->{func}{$ifunc}{time}/$JR->{mtime} > 0.01){ 
   printf("$MPI_REP_FMT", $ifunc, 
	$JR->{func}{$ifunc}{time}, 
	$JR->{func}{$ifunc}{count}, 
	100*$JR->{func}{$ifunc}{time}/$JR->{mtime}, 
	100*$JR->{func}{$ifunc}{time}/$JR->{wtime});
    }
   }
 }

 }

 if($flags{report_terse}) {  ### Terse
  if($T->{nregion} > 1) {
   printf("# region :                [ntasks]     <wall>        <mpi>       [gflop/sec]\n");
 foreach $ireg (reverse(sort regbywtime keys %{$J->{region}} )) {
  $JR = \%{$J->{region}{$ireg}};
  printf("# %-21.21s %6d  %13.4f %13.4f      %.4e \n", 
	$ireg, 
	$JR->{ntasks},
	$JR->{wtime}/$JR->{ntasks},
	$JR->{mtime}/$JR->{ntasks},
	$JR->{gflop}/($JR->{wtime}/$JR->{ntasks}));
 }

  }
 }

 printf("%79s","###############################################################################\n");
 }


###
# Begin HTML report section {
###

 if($flags{report_html} || $flags{report_wload}) {


$html_dir = $J->{cmdline_base}."_".$J->{ntasks}."_".$J->{filename_base}."_ipm_".$J->{id};
system("rm -rf $html_dir");
mkdir($html_dir);
mkdir("$html_dir/pl");
mkdir("$html_dir/img");
$PLPRE = "$html_dir/pl";
$IMPRE = "$html_dir/img";

$ntpo = $J->{ntasks} + 1;
$nhpo = $J->{nhosts} + 1;

 printf("# data_acquire    = %d sec\n", $TACQ);

###
# Data workup { shared with wload reporting
###

 
 $TINT1 = time();
###
# now we are prepared to check {func} vs. {hash} to detect spillage
# spillage means the hash table was so full some detail was thrown away
###
 
 $J->{hash_time} = 0.0;
 foreach $icall (keys %{$J->{mpi}{call}}) {
  $J->{hash_time}  += $J->{mpi}{call}{$icall}{ttot};
 }

 $JR->{hash_time} = 0.0;
 foreach $icall (keys %{$JR->{mpi}{call}}) {
  $JR->{hash_time}  += $JR->{mpi}{call}{$icall}{ttot};
 }
                                                                                
###
# neighbor lists {
###
if ($J->{ntasks} <= $topology_tasks ) {
    foreach $irank (sort keys %{$J->{task}} ) {
	foreach $jrank (sort keys %{$J->{task}} ) {
	    if(defined($JR->{mpi}{data_tx}{$irank}{$jrank}) && $JR->{mpi}{data_tx}{$irank}{$jrank} > 0) {
		if(!defined( $JR->{mpi}{neigh_tx}{$irank})) { $JR->{mpi}{neigh_tx}{$irank} = 0; }
		$JR->{mpi}{neigh_tx}{$irank}++;
	    }
	    if(defined($JR->{mpi}{data_rx}{$irank}{$jrank}) && $JR->{mpi}{data_rx}{$irank}{$jrank} > 0) {
		if(!defined( $JR->{mpi}{neigh_rx}{$irank})) { $JR->{mpi}{neigh_rx}{$irank} = 0; }
		$JR->{mpi}{neigh_rx}{$irank}++;
	    }
	    if(defined($JR->{mpi}{data_txrx}{$irank}{$jrank}) && $JR->{mpi}{data_txrx}{$irank}{$jrank} > 0) {
		if(!defined( $JR->{mpi}{neigh_txrx}{$irank})) { $JR->{mpi}{neigh_txrx}{$irank} = 0; }
		$JR->{mpi}{neigh_txrx}{$irank}++;
	    }
	    if(defined($JR->{mpi}{data_tx}{$irank}{$jrank}) || defined($JR->{mpi}{data_rx}{$irank}{$jrank}) || defined($JR->{mpi}{data_txrx}{$irank}{$jrank})) {
		if(!defined( $JR->{mpi}{neigh}{$irank})) { $JR->{mpi}{neigh}{$irank} = 0; }
		$JR->{mpi}{neigh}{$irank}++;
	    }
	}
    }
}
###
# }
###
 
# foreach $ikey (reverse(sort jcallsizebyttot keys %{$J->{mpi}{call_size}})) {
#  ($icall,$ibyte) = split('!',$ikey);
#  print "call_size J $icall $ibyte $J->{mpi}{call_size}{$ikey}{count} $J->{mpi}{call_size}{$ikey}{ttot} $J->{mpi}{call_size}{$ikey}{tmin} $J->{mpi}{call_size}{$ikey}{tmax}\n";
# }

###
# } Data workup
###
 $TINT2 = time();
 printf("# data_workup     = %d sec\n", $TINT2-$TINT1);

###
# Report generation
###


 $TINT1 = time();
html_jobreg_report("",">$html_dir/index.html", $cookie);
 $TINT2 = time();
 printf("# html_all        = %d sec\n", $TINT2-$TINT1);

 $TINT1 = time();
if($J->{nregion} > 1) {
foreach $ireg (reverse(sort regbywtime keys %{$J->{region_name}})) {
   html_jobreg_report($ireg,">$html_dir/index_$ireg.html", $cookie);
}
}
 $TINT2 = time();
 printf("# html_regions    = %d sec\n", $TINT2-$TINT1);

###
# Executable information {
###

 open(FH,">$html_dir/exec.html") or die("Can't open file\n");
 print FH <<EOF;
<html>
<body>
<a href="index.html">Back</a>
<table border=1 width=100%>
<tr>
<th align=left bgcolor=lightblue> Executable </th>
</th>
</tr>
<tr>
<td width=100%>
$jobs{$cookie}{task}{0}{exec}
</td>
</tr>
<tr>
<th align=left bgcolor=lightblue> Executable Binary Details </th>
</th>
</tr>
<tr>
<td>
<pre>
$jobs{$cookie}{task}{0}{exec_bin}
</pre>
</td>
</tr>
</table>
<a href="index.html">Back</a>
<body>
</html>
EOF
close(FH);
###
# }
###

###
# Hostlist
###

 open(FH,">$html_dir/hostlist.html") or die("Can't open file\n");
 print FH <<EOF;
<html>
<body>
<a href="index.html">Back</a>
<table border=1 width=100%>
<tr>
<th valign=top align=left bgcolor=lightblue> Hostlist </th>
<th valign=top align=left bgcolor=lightblue> Tasks </th>
</tr>
EOF
                                                                                
 foreach $ihost (sort keys %{$J{hostlist}}) {
  $hlist = "<tr><td>$ihost</td><td>";
  foreach $irank (sort keys %{$J{hostlist}{$ihost}}) {
   $hlist = $hlist."$irank,";
  }
  chop($hlist);
  $hlist = $hlist."</td></tr>\n";
  print FH $hlist;
 }
                                                                                
                                                                                
print FH <<EOF;
                                                                                
</td>
</tr>
</table>
<a href="index.html">Back</a>
<body>
</html>
EOF
close(FH);

###
# Environment {
###

open(FH,">$html_dir/env.html") or die("Can't open file\n");
 print FH <<EOF;
<html>
<body>
<a href="index.html">Back</a>
<pre>
$J->{env};
</pre>
<a href="index.html">Back</a>
<body>
</html>
EOF
close(FH);

###
# }
###

###
# Developer Info {
###

open(FH,">$html_dir/dev.html") or die("Can't open file\n");
 print FH <<EOF;
<html>
<body>
<a href="index.html">Back</a>

<font size=-1>
<table border=1 width=100%>
<tr> <th align=left bgcolor=lightblue> IPM Developer Section </th>
</th> </tr>
                                                                                
<tr> <th align=left bgcolor=lightblue> Report and Log timings </th>
</th> </tr>
<tr>
<td width=100%>
<img src="img/ipm_report_delta.$gfmt">
</td>
</tr>

<!--                                                                                
<tr> <th align=left bgcolor=lightblue> Hash table coverage (MPI) </th>
</th> </tr>
<tr>
<td width=100%>
<img src="ipm_hash_pmpi.$gfmt">
</td>
</tr>
-->

<tr> <th align=left bgcolor=lightblue> Hash table density </th>
</th> </tr>
<tr>
<td width=100%>
<img src="img/ipm_hash_nkey.$gfmt">
</td>
</tr>
                                                                                
</table>
                                                                                
</font>

<a href="index.html">Back</a>
<body>
</html>
EOF
close(FH);

###
# Developer Info }
###

###
# { Report IPM internal performance data : log times
###

 foreach $irank (sort numy keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  if(!defined($T->{logrep_max})) {
   $T->{logrep_max} = $T->{report_delta};
  }
  if($T->{log_t} > $T->{logrep_max}) {$T->{logrep_max} = $T->{log_t}};
  if($T->{report_delta} > $T->{logrep_max}) {$T->{logrep_max} = $T->{report_delta}};
 }
                                                                                
 $T->{logrep_max} *= 2.0;
 open(TFH,"> $PLPRE/intern_logrep") or die("Can't open file\n");
                                                                                
print TFH<<EOF;
#proc areadef
  rectangle: 1 1 6 4
  xrange: -1 $ntpo
  yrange: 0 $T->{logrep_max}
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.label: MPI rank
  yaxis.label: time (seconds)
  xaxis.stubrange: 0 $J->{ntasks}
  xaxis.stubvert: yes
  yscaletype: log
                                                                                
EOF
                                                                                
 printf TFH "#proc getdata\ndata:\n";
                                                                                
 foreach $irank (sort numy keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  printf TFH "$irank $T->{rank} $T->{log_i} $T->{log_t} $T->{report_delta} $T->{logrank} \n";
 }
                                                                                
print TFH<<EOF;
                                                                                
                                                                                
#proc lineplot
  xfield: 1
  yfield: 4
  legendlabel: ipm_syslog
  linedetails: color=red
  sort: yes
                                                                                
#proc lineplot
  xfield: 1
  yfield: 5
  legendlabel: ipm_report
  linedetails: color=green
  sort: yes
                                                                                
#proc legend
  location: max+0.4 max
//  reverseorder: yes
  seglen: 0.3
                                                                                
EOF
 close(TFH);
 system("$PLOTICUS $PLPRE/intern_logrep  -$gfmt  -o $IMPRE/ipm_report_delta.$gfmt ");
                                                                                
###
# }
###
                                                                                
###
# { Report IPM internal performance data : hash density
###
                                                                                
 $nkeymax = 0;
 foreach $irank (sort numy keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  if($T->{hash_diag}{nkey} > $nkeymax) { $nkeymax = $T->{hash_diag}{nkey};}
 }
                                                                                
 $T->{logrep_max} *= 2.0;
 open(TFH,">$PLPRE/intern_hash") or die("Can't open file\n");
                                                                                
print TFH<<EOF;
#proc areadef
  rectangle: 1 1 6 4
  xrange: -1 $ntpo
  yrange: 0 $nkeymax
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.label: MPI rank
  yaxis.label: # hash entries
  xaxis.stubrange: 0 $J->{ntasks}
  xaxis.stubvert: yes
  yscaletype: log
                                                                                
EOF
                                                                                
 printf TFH "#proc getdata\ndata:\n";
                                                                                
 foreach $irank (sort numy keys %{$J->{task}} ) {
  $T = \%{$J->{task}{$irank}};
  printf TFH "$irank $T->{rank} $T->{hash_diag}{nkey} \n";
 }
                                                                                
print TFH<<EOF;
                                                                                
                                                                                
#proc lineplot
  xfield: 1
  yfield: 3
  legendlabel: nkeys
  linedetails: color=red
  sort: yes
                                                                                
#proc legend
  location: max+0.4 max
//  reverseorder: yes
  seglen: 0.3
                                                                                
EOF
 close(TFH);
 system("$PLOTICUS $PLPRE/intern_hash -$gfmt  -o $IMPRE/ipm_hash_nkey.$gfmt ");
                                                                                
###
# }
###



###
# Clean up
###
if($flags{clean} == 1) {unlink("$PLPRE");}


 if($flags{report_wload}) {
  foreach $ireg (sort keys %{$J->{region}} ) {
  print "$cookie $ireg\n";
  $JR =\%{$jobs{$cookie}{region}{$ireg}};
  foreach $ikey (reverse(sort jcallsizebyttot keys %{$JR->{mpi}{call_size}})) {
   ($icall,$ibyte) = split('!',$ikey);
   next if($ibyte == 0);
   print FH "$icall $ibyte $JR->{mpi}{call_size}{$ikey}{count} $JR->{mpi}{call_size}{$ikey}{ttot} $JR->{mpi}{call_size}{$ikey}{tmin} $JR->{mpi}{call_size}{$ikey}{tmax} $JR->{mpi}{call_size}{$ikey}{ttot} $JR->{mpi}{call_size}{$ikey}{count} ".(100*$JR->{mpi}{call_size}{$ikey}{ttot}/$JR->{mpi}{call}{$icall}{ttot})." ".(100*$JR->{mpi}{call_size}{$ikey}{count}/$JR->{mpi}{call}{$icall}{count})."\n";
  }
 }
 }
 $TINT2 = time();
 printf("# html_nonregion  = %d sec\n", $TINT2-$TINT1);
}
###
# End HTML report section }
###

###
# Start JSON report section {
###
 if($flags{report_json}) {
# 	$J->{wtime|utime|stime|mtime|pop|gflop|nhosts|ntasks|hostname}

# compute derived metrics

# generate report as heredoc 

  $JSON_REPORT = <<END;
{
 "username":$J->{username},
 "cmdline":$J->{cmdline},
 "ntasks":$J->{ntasks},
 "nhosts:"$J->{nhosts},
 "wtime":$J->{wtime},
 "utime":$J->{utime},
 "stime":$J->{stime},
 "mtime":$J->{mtime},
 "iotime":$J->{iotime},
 "pct_comm":$J->{pcomm},
 "pct_io":$J->{pio},
 "gbyte":$J->{gbyte},
 "gflop":$J->{gflop}
}
END
 print $JSON_REPORT;
 }
###
# End JSON report section }
###

####
#  Report Generation  }
####

###
} # next cookie
###

exit(0); 


###
# End of Main. subroutines etc. follow
###


sub html_jobreg_report {
 my ($TINT1,$TINT2);
 my $ireg = shift;
 my $fname = shift;
 my $cookie = shift;
 my $J;
 my $JR;
 my $FH;



###
# Initialize {
###
 if($ireg eq "") {
  $J =\%{$jobs{$cookie}};
  $JR =\%{$jobs{$cookie}};
  $report_all = 1;
  $tag = "";
  $rtag = "ipm_global";
  $htag = $J->{id};
 } else {
  $J =\%{$jobs{$cookie}};
  $JR =\%{$jobs{$cookie}{region}{$ireg}};
  $report_all = 0;
  $tag = "_".$ireg;
  $rtag = $ireg;
  $htag = $J->{id}."::$ireg";
 }


###
# }
###

###
# Graph and datafile generation  {
###

$TINT1 = time();
###
# Graphs by <func> and <region> {
###
                                                           
 open(FH,">$PLPRE/mpi_pie$tag") or die("Can't open file\n");
 if($JR->{mtime} > 0.0) {
 $i = 0;
 print FH <<EOF;
#proc page
                                                                                
#proc areadef
  rectangle: 0 0 2.5 2
  xrange: 0 1
  yrange: 0 1
//  xaxis.tics: none
//  yaxis.tics: none
//  xaxis.stubhide: yes
//  yaxis.stubhide: yes
                                                                                
#proc getdata
EOF
                                                                                
 print FH " data:\n";
 
 $i = 0;
 foreach $ifunc (reverse(sort jfuncbyttot keys %{$JR->{func}})) {
  $ipm_color_bycall{$ifunc} = $ipm_color[$i];
  $i++;
 }
   
 foreach $ifunc (reverse(sort jfuncbyttot keys %{$JR->{func}})) {
  $pct = int($JR->{func}{$ifunc}{time}/$JR->{mtime}*10000)/100;
  print FH "$ifunc $JR->{func}{$ifunc}{time} $ipm_color_bycall{$ifunc} $ifunc\n";
 }
 
print FH<<EOF;
 
#proc pie
 firstslice: 0
 datafield: 2
 labelfield: 1
 exactcolorfield: 3
 center: 0.5(s) 0.6(s)
 radius: 0.4(s)
  
#proc legend
 location: 1.1(s) 1.2(s)
 
EOF
 } else {
print FH<<EOF;
#proc areadef
  rectangle: 0 0 3.5 3
  xrange: 0 1
  yrange: 0 2
                                                                                
#proc annotate
  location: 1 3
  textdetails: size=32 color=black
  backcolor: white
  text: None
EOF
 }
 
 close(FH);
 system("$PLOTICUS $PLPRE/mpi_pie$tag -$gfmt -o  $IMPRE/mpi_pie$tag.$gfmt");
 
 
###
# }
###
 $TINT2 = time();
 printf("#  mpi_pie        = %d sec\n",$TINT2-$TINT1,$tag);

 $TINT1 = time();
 open(FH,">$html_dir/task_data$tag") or die("Can't open file\n");
 print FH "//#rank ";
 foreach $icounter (sort keys %{$JR->{counter} } ) {
  print FH "$icounter ";
 }
 print FH "wtime utime stime mtime pcomm gbyte gflop bytes_tx bytes_rx\n";
  
 $i = 0;
 foreach $irank (reverse(sort taskbymtime keys %{$J->{task}})) {
   if($report_all == 1) {
    $TR = \%{$J->{task}{$irank}};
   } else {
    $TR = \%{$J->{task}{$irank}{region}{$ireg}};
   }

  print FH "$irank ";
  foreach $icounter (sort keys %{$TR->{counter} } ) {
   if( (defined($TR->{counter}{$icounter}{count})) && ($JR->{counter}{$icounter}{count_max} != 0)) {
#    print FH "$TR->{counter}{$icounter}{count}/$JR->{counter}{$icounter}{count_max} ";
    print FH 100*$TR->{counter}{$icounter}{count}/$JR->{counter}{$icounter}{count_max}." ";
   } else {
    print FH "= ";
   }
  } 

if($JR->{wtime_max}>0){$w_rat=100*$TR->{wtime}/$JR->{wtime_max};}else{$w_rat=0.0;}
if($JR->{utime_max}>0){$u_rat=100*$TR->{utime}/$JR->{utime_max};}else{$u_rat=0.0;}
if($JR->{stime_max}>0){$s_rat=100*$TR->{stime}/$JR->{stime_max};}else{$s_rat=0.0;}
if($JR->{mtime_max}>0){$m_rat=100*$TR->{mtime}/$JR->{mtime_max};}else{$m_rat=0.0;}
   if($report_all == 1) {
if($JR->{gbyte_max}>0){$b_rat=100*$TR->{gbyte}/$JR->{gbyte_max};}else{$b_rat=0.0;}
   } else {
    $b_rat = 0.0;
   }
if($JR->{gflop_max}>0){$f_rat=100*$TR->{gflop}/$JR->{gflop_max};}else{$f_rat=0.0;}
if($JR->{byte_tx_max}>0){$t_rat=100*$TR->{byte_tx}/$JR->{byte_tx_max};}else{$t_rat="=";}
if($JR->{byte_rx_max}>0){$r_rat=100*$TR->{byte_rx}/$JR->{byte_rx_max};}else{$r_rat="=";}
  print FH "$w_rat $u_rat $s_rat $m_rat $b_rat $f_rat $t_rat $r_rat\n";
 }

 print FH "\n";
 print FH "\n";

 close(FH);
 $TINT2 = time();
 printf("#  task_data      = %d sec\n",$TINT2-$TINT1,$tag);

$TINT1 = time();
###
# course load (im)balance  {
###

 open(FH,">$PLPRE/task_multi$tag") or die("Can't open file\n");
 print FH<<EOF;

#set TIMES = 1
#set FLOPS = 1
#set BYTES = 1
#set HPMCT = 0
#set SWICH = 1

#proc getdata:
  command: cat $html_dir/task_data$tag

#proc areadef
  rectangle: 1 1 6 4
  xrange: 0 $ntpo
  yrange: 0 100
//  yautorange: datafield=2,3,4,5,6,7,8,9,10,11,12,13,14 hifix=100
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.label: MPI rank 
  yaxis.label: % of maximum across MPI ranks
  xaxis.stubrange: 0 $JR->{ntasks}
  xaxis.labeldistance: 0.5
  xaxis.stubvert: yes


EOF
                                                                            

print FH<<EOF;

#if \@HPMCT = 1

EOF

 $i = 2;
 foreach $icounter (sort keys %{$TR->{counter} } ) {
 print FH<<EOF;

#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
 xfield: 1
 yfield: $i
 legendlabel: $icounter
 linedetails: color=$ipm_color[$i-2]
 sort: yes

EOF
 $i = $i +1;
}

print FH<<EOF;

#endif

EOF


print FH<<EOF;

#if \@TIMES = 1

#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: wtime
  linedetails: color=$ipm_color[$i-1]
 sort: yes

EOF

$i = $i +1;
print FH<<EOF;
#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: utime
  linedetails: color=$ipm_color[$i-1]
 sort: yes

EOF

$i = $i +1;
print FH<<EOF;
#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: stime
  linedetails: color=$ipm_color[$i-1]
 sort: yes

EOF

$i = $i +1;
print FH<<EOF;
#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: mtime
  linedetails: color=$ipm_color[$i-1]
 sort: yes

#endif

EOF

$i = $i +1;
if($report_all == 1) {
print FH<<EOF;

#if \@BYTES = 1

#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: gbyte
  linedetails: color=$ipm_color[$i-1]
 sort: yes

#endif
EOF
}

$i = $i +1;
print FH<<EOF;

#if \@FLOPS = 1
#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: gflop
  linedetails: color=$ipm_color[$i-1]
 sort: yes

#endif

EOF

$i = $i +1;
print FH<<EOF;

#if \@SWICH = 1

#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: bytes_tx
  linedetails: color=$ipm_color[$i-1]
 sort: yes

EOF

$i = $i +1;
print FH<<EOF;
#proc getdata:
  command: sort -n $html_dir/task_data$tag

#proc lineplot
  xfield: 1
  yfield: $i
  legendlabel: bytes_rx
  linedetails: color=$ipm_color[$i-1]
 sort: yes

#endif
EOF

print FH<<EOF;

#proc legend
  location: max+0.4 max
//  reverseorder: yes
  seglen: 0.3

EOF
 close(FH);

# roadkill can write better code than this

 system("$PLOTICUS $PLPRE/task_multi$tag  -$gfmt  -o $IMPRE/load_multi_rank$tag.$gfmt ");
 system("sed -e 's/#set TIMES = 1/#set TIMES = 0/;s/#set FLOPS = 1/#set FLOPS = 0/;s/#set BYTES = 1/#set BYTES = 0/;s/#set HPMCT = 0/#set HPMCT = 1/;s/#set SWICH = 1/#set SWICH = 0/' $PLPRE/task_multi$tag > $PLPRE/task_hpm$tag");
 system("$PLOTICUS $PLPRE/task_hpm$tag  -$gfmt  -o $IMPRE/load_hpm_rank$tag.$gfmt ");
 system("grep -v \"xfield: 1\" $PLPRE/task_multi$tag  | sed -e 's/MPI rank /sorted index/;s/command: sort -n/command: cat/'> $PLPRE/taskm_multi$tag");
 system("$PLOTICUS $PLPRE/taskm_multi$tag  -$gfmt  -o $IMPRE/load_multi_mtime$tag.$gfmt ");
 system("sed -e 's/#set TIMES = 1/#set TIMES = 0/;s/#set FLOPS = 1/#set FLOPS = 0/;s/#set BYTES = 1/#set BYTES = 0/;s/#set HPMCT = 0/#set HPMCT = 1/;s/#set SWICH = 1/#set SWICH = 0/' $PLPRE/taskm_multi$tag > $PLPRE/taskm_hpm$tag");
 system("$PLOTICUS $PLPRE/taskm_hpm$tag  -$gfmt  -o $IMPRE/load_hpm_mtime$tag.$gfmt ");
 system("awk 'BEGIN{field=1};(\$1==\"command:\" && \$2==\"cat\"){print \"  command: sort -n -k\"field, \$3; field++;};(\$1!=\"command:\" && \$2!=\"cat\"){print \$0}' $PLPRE/taskm_multi$tag | sed -e 's/sorted index/individually sorted indices/' > $PLPRE/taska_multi$tag");
 system("$PLOTICUS $PLPRE/taska_multi$tag  -$gfmt  -o $IMPRE/load_multi$tag.$gfmt ");
 system("sed -e 's/#set TIMES = 1/#set TIMES = 0/;s/#set FLOPS = 1/#set FLOPS = 0/;s/#set BYTES = 1/#set BYTES = 0/;s/#set HPMCT = 0/#set HPMCT = 1/;s/#set SWICH = 1/#set SWICH = 0/' $PLPRE/taska_multi$tag > $PLPRE/taska_hpm$tag");
 system("$PLOTICUS $PLPRE/taska_hpm$tag  -$gfmt  -o $IMPRE/load_hpm_all$tag.$gfmt ");

###
# Load Balance }
###
 $TINT2 = time();
 printf("#  load_bal       = %d sec\n", $TINT2-$TINT1,$tag);

$TINT1 = time();
###
# Graphs of (wusm)time usage by task {
###
 
 open(FH,">$PLPRE/time_stack_bymtime$tag") or die("Can't open file\n");

 $ymax = $JR->{utime_max} + $JR->{stime_max};
 print FH<<EOF;
#proc areadef
  rectangle: 1 1 6 4
  xrange: -1 $ntpo
  yrange:  0 $ymax
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.stubrange: 0 $JR->{ntasks}
  xaxis.stubvert: yes
  xaxis.label: sorted index
  xaxis.labeldistance: 0.5
  yaxis.label: time in seconds
                                                                                
#proc getdata
EOF
 $i= 0;
 print FH "data:\n";
 foreach $irank (reverse(sort taskbymtime keys %{$J->{task}} )) {
   if($report_all == 1) {
    $TR = \%{$J->{task}{$irank}};
   } else {
    $TR = \%{$J->{task}{$irank}{region}{$ireg}};
   }
  print FH "$i $irank $TR->{wtime} $TR->{utime} $TR->{stime} $TR->{mtime} ";
  print FH  $TR->{wtime}-$TR->{mtime};
  print FH "\n";
  $i ++;
 }
                                                                                
print FH<<EOF;
                                                                                
 #proc bars
  lenfield: 4
  locfield: 1
  color: $ipm_color[2]
  legendlabel: user 
  barwidth: $barwidth
  outline: no
  #saveas A

 #proc bars
  #clone: A
  lenfield: 5
  color: $ipm_color[3]
  legendlabel: system
  stackfields: *
                                                                                
#proc lineplot
 xfield: 1
 yfield: 3
 legendlabel: wall
 linedetails: color=$ipm_color[0]
 sort: yes

#proc lineplot
 xfield: 1
 yfield: 6
 legendlabel: mpi
 linedetails: color=$ipm_color[1]
 sort: yes

#proc legend
  location: max+0.4 max
  seglen: 0.3

EOF
                                                                                
 close(FH);
 $cmd = "$PLOTICUS $PLPRE/time_stack_bymtime$tag -$gfmt -o $IMPRE/time_stack_bymtime$tag.$gfmt";
system($cmd);

###
# Now reorganize to show by rank
###
 system("sed -e 's/locfield: 1/locfield: 2/;s/sorted index/MPI rank/;s/xfield: 1/xfield: 2/' $PLPRE/time_stack_bymtime$tag > $PLPRE/time_stack_byrank$tag");
 system("$PLOTICUS $PLPRE/time_stack_byrank$tag -$gfmt -o $IMPRE/time_stack_byrank$tag.$gfmt");

###
# } Graphs of (wusm)time usage by task 
###
 $TINT2 = time();
 printf("#  time_stack     = %d sec\n",$TINT2-$TINT1,$tag);

$TINT1 = time();
###
# Graphs of MPI usage by task  {
###
 
 open(FH,">$PLPRE/mpi_stack_bymtime$tag") or die("Can't open file\n");
 if($JR->{mtime} > 0) {
 $i = 0;
 print FH<<EOF;
#proc areadef
  rectangle: 1 1 6 4
  xrange: -1 $ntpo
  yrange:  0 $JR->{mtime_max}
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.stubrange: 0 $JR->{ntasks}
  xaxis.stubvert: yes
  xaxis.label: sorted index
  xaxis.labeldistance: 0.5
  yaxis.label: time in seconds
                                                                                
#proc getdata
EOF
 print FH "data:\n";
 foreach $irank (reverse(sort taskbymtime keys %{$J->{task}} )) {
   if($report_all == 1) {
    $TR = \%{$J->{task}{$irank}};
   } else {
    $TR = \%{$J->{task}{$irank}{region}{$ireg}};
   }
  print FH "$i $irank $TR->{wtime} $TR->{utime} $TR->{stime} $TR->{mtime} ";
  print FH  $TR->{wtime}-$TR->{mtime};
  print FH  " ";
  foreach $icall (reverse(sort jcallbyttot keys %{$JR->{mpi}{call}})) {
   if(defined($TR->{mpi}{call}{$icall}{ttot})) {
    print FH "$TR->{mpi}{call}{$icall}{ttot} ";
   } else {
    print FH "= ";
   }
  }
  print FH "\n";
  $i ++;
 }
                                                                                
  $i = 0;
  $stack = "";
  foreach $icall (reverse(sort jcallbyttot keys %{$JR->{mpi}{call}})) {
                                                                                
  $j = $i+8;
                                                                                
 if($i==0) {
$barwidth= 4.0/$ntpo;
print FH<<EOF;
                                                                                
 #proc bars
  lenfield: $j
  locfield: 1
  color: $ipm_color[$i]
  legendlabel: $icall
  barwidth: $barwidth
  outline: no
  #saveas A
EOF
 } else {
print FH<<EOF;
 #proc bars
  #clone: A
  lenfield: $j
  color: $ipm_color[$i]
  legendlabel: $icall
  stackfields: *
                                                                                
EOF
 }
                                                                                
 $i++;
  $stack = $stack." $j";
 }
                                                                                
print FH<<EOF;
 
#proc legend
  location: max+0.4 max
  seglen: 0.3
EOF
                                                                                
 } else {
 print FH<<EOF;
#proc areadef
  rectangle: 0 0 3.5 3
  xrange: 0 1
  yrange: 0 2
                                                                                
#proc annotate
  location: 1 3
  textdetails: size=32 color=black
  backcolor: white
  text: None
EOF
 }

 close(FH);
 $cmd = "$PLOTICUS $PLPRE/mpi_stack_bymtime$tag -$gfmt -o $IMPRE/mpi_stack_bymtime$tag.$gfmt";
system($cmd);

###
# Now reorganize to show by rank
###
 system("sed -e 's/locfield: 1/locfield: 2/;s/sorted index/MPI rank/' $PLPRE/mpi_stack_bymtime$tag > $PLPRE/mpi_stack_byrank$tag");
 $cmd = "$PLOTICUS $PLPRE/mpi_stack_byrank$tag -$gfmt -o $IMPRE/mpi_stack_byrank$tag.$gfmt";
system($cmd);
###
# } Graphs of MPI usage by task  
###
 $TINT2 = time();
 printf("#  mpi_stack      = %d sec\n",$TINT2-$TINT1,$tag);
 

$TINT1 = time();
###
# Graphs by buffer size {
###
 
 open(FH,"> $PLPRE/mpi_buff_time$tag") or die("Can't open file\n");

 %do_callsize = ();
 foreach $icall (keys %{$JR->{mpi}{call}}) {
  foreach $ikey (keys %{$JR->{mpi}{call_size}}) {
   ($icall,$ibyte) = split('!',$ikey);
   $do_callsize{$icall} ++;
  }
 }
 
 $max_byte = $min_byte = -1;
 $max_call = $min_call = -1;
 $max_time = $min_time = -1;
 
 foreach $icall (reverse(sort jcallbyttot keys %{$JR->{mpi}{call}})) {
#  next if($JR->{mpi}{call}{$icall}{count} == 0);
  next if($do_callsize{$icall} == 0);
  if($min_call < 0) {$min_call = $JR->{mpi}{call}{$icall}{count} ;}
  if($max_call < 0) {$max_call = $JR->{mpi}{call}{$icall}{count} ;}
  if($JR->{mpi}{call}{$icall}{count} > $max_call) {
         $max_call = $JR->{mpi}{call}{$icall}{count};
  }
  if($JR->{mpi}{call}{$icall}{count} < $min_call) {
         $min_call = $JR->{mpi}{call}{$icall}{count};
  }
 }

 foreach $ikey (reverse(sort jcallsizebyttot keys %{$JR->{mpi}{call_size}})) {
  ($icall,$ibyte) = split('!',$ikey);
  next if($ibyte == 0);
  if($min_byte < 0) {$min_byte = $ibyte;}
  if($max_byte < 0) {$max_byte = $ibyte;}
  if($ibyte < $min_byte) {$min_byte = $ibyte;}
  if($ibyte > $max_byte) {$max_byte = $ibyte;}
  if($min_time < 0) {$min_time = $JR->{mpi}{call_size}{$ikey}{ttot};}
  if($max_time < 0) {$max_time = $JR->{mpi}{call_size}{$ikey}{ttot};}
  if($JR->{mpi}{call_size}{$ikey}{ttot} < $min_time) {$min_time = $JR->{mpi}{call_size}{$ikey}{ttot};}
  if($JR->{mpi}{call_size}{$ikey}{ttot} > $max_time) {$max_time = $JR->{mpi}{call_size}{$ikey}{ttot};}
 }

 if($JR->{mtime} > 0.0 && $max_byte >= 0 && $min_byte >= 0) {
  $i = 0;
  $j = 0;
  if($max_byte == $min_byte) {
   $max_byte += 1;
   if($min_byte > 1) { $min_byte -= 1; }
  }

  if($max_call == $min_call) {
   $max_call += 1;
   if($min_call > 1) { $min_call -= 1; }
  }

printf FH "#proc getdata:\ndata:\n";
 
 
 foreach $ikey (reverse(sort jcallsizebyttot keys %{$JR->{mpi}{call_size}})) {
  ($icall,$ibyte) = split('!',$ikey);
  next if($ibyte == 0);
  print FH "$icall $ibyte $JR->{mpi}{call_size}{$ikey}{count} $JR->{mpi}{call_size}{$ikey}{ttot} $JR->{mpi}{call_size}{$ikey}{tmin} $JR->{mpi}{call_size}{$ikey}{tmax} $JR->{mpi}{call_size}{$ikey}{ttot} $JR->{mpi}{call_size}{$ikey}{count} ".(100*$JR->{mpi}{call_size}{$ikey}{ttot}/$JR->{mpi}{call}{$icall}{ttot})." ".(100*$JR->{mpi}{call_size}{$ikey}{count}/$JR->{mpi}{call}{$icall}{count})."\n";
 }
 
print FH<<EOF;
 
 
#proc areadef
rectangle: 1 1 6 4
xautorange: $min_byte $max_byte
yrange: 0 100
yaxis.stubs: inc
xscaletype: log
// yscaletype: log
yaxis.label: % comm time <= buffer size
 
#proc xaxis
  label: Buffer size (bytes)
  selflocatingstubs: text
        1          1
        4          4
        16         16
        64         64
        256        256
        1024       1KB
        4096       4KB
        16384      16KB
        65536      64KB
        262144     256KB
        1048576    1MB
        4194304    4MB
        16777216   16MB
        67108864   64MB
        268435456  128MB
        1073741824 512MB
  
EOF
 
  foreach $icall (reverse(sort jcallbyttot keys %{$JR->{mpi}{call}})) {
   next if($do_callsize{$icall} == 0);
#  next if($mpi_call{$icall}{dat} =~/DATA_NONE/ && $icall != "MPI_Wait");
 
print FH<<EOF;
 
#proc lineplot
xfield: 2
yfield: 9
sort: yes
accum: yes
select: \@\@1 = $icall
linedetails: color=$ipm_color_bycall{$icall}
legendlabel: $icall
pointsymbol: shape=circle linecolor=black radius=0.03 fillcolor=$ipm_color_bycall{$icall}
 
EOF
  }
 
print FH<<EOF;
#proc legend
location: max-0.5 max-0.5
EOF
} else {
print FH<<EOF;
#proc areadef
  rectangle: 0 0 3.5 3
  xrange: 0 1
  yrange: 0 2
                                                                                
#proc annotate
  location: 1 3
  textdetails: size=32 color=black
  backcolor: white
  text: None
EOF
}
close(FH);
 
system("$PLOTICUS $PLPRE/mpi_buff_time$tag -$gfmt -o $IMPRE/mpi_buff_time$tag.$gfmt");
system("grep -v \"accum: yes\" $PLPRE/mpi_buff_time$tag | sed -e 's/yrange: 0 100/yautorange: ".$min_time." ".$max_time."/;s/\\/\\/ yscale/ yscale/;s/yfield: 9/yfield: 7/;s/% comm time <= buffer size/comm time/'  > $PLPRE/mpi_buff_time_hist$tag");
system("$PLOTICUS $PLPRE/mpi_buff_time_hist$tag -$gfmt -o $IMPRE/mpi_buff_time_hist$tag.$gfmt");
system("cat $PLPRE/mpi_buff_time$tag | sed -e 's/yrange: 0 100/yautorange: 0 ".$JR->{mtime}."/;s/yfield: 9/yfield: 7/;s/% comm time <= buffer size/comm time <= buffer size/'  > $PLPRE/mpi_buff_time_abs$tag");
system("$PLOTICUS $PLPRE/mpi_buff_time_abs$tag -$gfmt -o $IMPRE/mpi_buff_time_abs$tag.$gfmt");
 
system("sed -e 's/yfield: 9/yfield: 10/;s/comm time/calls/' $PLPRE/mpi_buff_time$tag > $PLPRE/mpi_buff_call$tag");
system("$PLOTICUS $PLPRE/mpi_buff_call$tag -$gfmt -o $IMPRE/mpi_buff_call$tag.$gfmt");
system("grep -v \"accum: yes\" $PLPRE/mpi_buff_call$tag | sed -e 's/yrange: 0 100/yautorange: ".$min_call." ".$max_call."/;s/\\/\\/ yscale/ yscale/;s/yfield: 10/yfield: 8/;s/% calls <= buffer size/# calls/'  > $PLPRE/mpi_buff_call_hist$tag");
system("$PLOTICUS $PLPRE/mpi_buff_call_hist$tag -$gfmt -o $IMPRE/mpi_buff_call_hist$tag.$gfmt");
system("cat $PLPRE/mpi_buff_call$tag | sed -e 's/yrange: 0 100/yautorange: ".$min_call." ".$max_call."/;s/\\/\\/ yscale/ yscale/;s/yfield: 10/yfield: 8/;s/% calls <= buffer size/# calls <= buffer size/'  > $PLPRE/mpi_buff_call_abs$tag");
system("$PLOTICUS $PLPRE/mpi_buff_call_abs$tag -$gfmt -o $IMPRE/mpi_buff_call_abs$tag.$gfmt");
 
 
###
# }
###
 $TINT2 = time();
 printf("#  mpi_buff       = %d sec\n", $TINT2-$TINT1,$tag);
 
 $TINT1 = time();
###
# Graphs for switch events  {
###

 if($report_all == 1) {
 $max_gbyte = 0;
 foreach $ihost(reverse(sort hostbyswitch keys %{$J->{host}} )) {
  $igbyte = $J->{host}{$ihost}{gbyte_tx} + $J->{host}{$ihost}{gbyte_rx};
  if($igbyte > $max_gbyte) { $max_gbyte = $igbyte; }
 }
 
 open(FH,">$PLPRE/switch_stack_bydata$tag") or die("Can't open file\n");
 if($max_gbyte > 0) {
 print FH<<EOF;
#proc areadef
  rectangle: 1 1 6 4
  xrange: -1 $nhpo
  yrange:  0 $max_gbyte
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.stubrange: 0 $J->{nhosts}
  xaxis.stubvert: yes
  xaxis.label: sorted index
  yaxis.label: GBytes
                                                                                
#proc getdata
EOF
 $i = 0;
 print FH "data:\n";
 foreach $ihost(reverse(sort hostbyswitch keys %{$J->{host}} )) {
  print FH "$i $ihost $J->{host}{$ihost}{gbyte_tx} $J->{host}{$ihost}{gbyte_rx}\n";
  $i ++;
 }
                                                                                
$barwidth= 4.0/$nhpo;
print FH<<EOF;
                                                                                
 #proc bars
  lenfield: 3
  locfield: 1
  color: $ipm_color[0]
  legendlabel: gbytes_tx
  barwidth: $barwidth
  outline: no
  #saveas A
 
 #proc bars
  #clone: A
  lenfield: 4
  color: $ipm_color[1]
  legendlabel: gbytes_rx
  stackfields: *
                                                                                
 
#proc legend
  location: max+0.4 max
  seglen: 0.3
EOF
                      
 } else {
print FH<<EOF;
#proc areadef
  rectangle: 0 0 3.5 3
  xrange: 0 1
  yrange: 0 2
                                                                                
#proc annotate
  location: 1 3
  textdetails: size=32 color=black
  backcolor: white
  text: None
EOF
 
 }
 close(FH);
                                                                                
                                                                                
 system("$PLOTICUS $PLPRE/switch_stack_bydata$tag -$gfmt -o $IMPRE/switch_stack_bydata.$gfmt");
 }
 
###
# }
###
 
###
# Graphs of memory usage by task  {
###
 
 if($report_all == 1) {
 $max_gbyte = 0;
 foreach $ihost(reverse(sort hostbyswitch keys %{$J->{host}} )) {
  $igbyte = $J->{host}{$ihost}{gbyte};
  if($igbyte > $max_gbyte) { $max_gbyte = $igbyte; }
 }
 
 open(FH,">$PLPRE/mem_stack_bymem$tag") or die("Can't open file\n");
 print FH<<EOF;
#proc areadef
  rectangle: 1 1 6 4
  xrange: -1 $nhpo
  yrange:  0 $max_gbyte
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.stubrange: 0 $J->{nhosts}
  xaxis.stubvert: yes
  xaxis.label: sorted index
  yaxis.label: GBytes
                                                                                
#proc getdata
EOF
 $i = 0;
 print FH "data:\n";
 foreach $ihost(reverse(sort hostbymem keys %{$J->{host}} )) {
  print FH "$i $ihost $J->{host}{$ihost}{gbyte}\n";
  $i ++;
 }
                                                                                
$barwidth= 4.0/($nhpo+1);
print FH<<EOF;
                                                                                
 #proc bars
  lenfield: 3
  locfield: 1
  color: $ipm_color[0]
  legendlabel: gbytes
  barwidth: $barwidth
  outline: no
  #saveas A
 
#proc legend
  location: max+0.4 max
  seglen: 0.3
EOF
                                                                                
 close(FH);
                                                                                
                                                                                
 $cmd = "$PLOTICUS $PLPRE/mem_stack_bymem$tag -$gfmt -o $IMPRE/mem_stack_bymem.$gfmt";
system($cmd);
}
###
# }
###
 $TINT2 = time();
 printf("#  switch+mem     = %d sec\n", $TINT2-$TINT1,$tag);

$TINT1 = time();
###
# MPI topology : tables {
###
if ($J->{ntasks} >= $topology_tasks ){
    print "\n By default communication topology is not calculated for more than $topology_tasks MPI tasks\n";
    print " This behavior can be overidden with -force-topology.";
    print " Use this option with care\n the CPU & memory requirement grow";
    print " quadratically with the number of MPI tasks.\n\n";

}else {


 if($report_all == 1) {
 open(FH,">$html_dir/map_calls.txt") or die("Can't open file\n");

 print FH "#region irank jrank  MPI_call buffer_size ncalls total_time min_time max_time\n";
 foreach $icall (keys %{$J->{hash}}) {
  foreach $ibyte (keys %{$J->{hash}{$icall}}) {
   foreach $irank (keys %{$J->{hash}{$icall}{$ibyte}}) {
    foreach $iorank (keys %{$J->{hash}{$icall}{$ibyte}{$irank}}) {
     foreach $jreg (keys %{$J->{hash}{$icall}{$ibyte}{$irank}{$iorank}}) {
      print FH "$jreg $irank $iorank $icall $ibyte $J->{hash}{$icall}{$ibyte}{$irank}{$iorank}{$jreg}{count} $J->{hash}{$icall}{$ibyte}{$irank}{$iorank}{$jreg}{ttot} $J->{hash}{$icall}{$ibyte}{$irank}{$iorank}{$jreg}{tmin} $J->{hash}{$icall}{$ibyte}{$irank}{$iorank}{$jreg}{tmax}\n";
     }
    }
   }
  }
 }
 close(FH);
 }

 open(FH,">$html_dir/map_data$tag.txt") or die("Can't open file\n");

 print FH "# region irank jrank data_tot data_tx data_rx nmsg_tx nmsg_rx\n";
 foreach $irank (sort numy keys %{$J->{task}} ) {
  foreach $jrank (sort numy keys %{$J->{task}} ) {
   next if($jrank > $irank);
   $data_ij = 0;
   if(defined($JR->{mpi}{data_tx}{$irank}{$jrank})) {
     $data_ij += $JR->{mpi}{data_tx}{$irank}{$jrank};
   }
   if(defined($JR->{mpi}{data_rx}{$irank}{$jrank})) {
     $data_ij += $JR->{mpi}{data_rx}{$irank}{$jrank};
   }

   if($data_ij > 0) {
    if(!defined($JR->{mpi}{data_tx}{$irank}{$jrank})) {
     $JR->{mpi}{data_tx}{$irank}{$jrank} = 0;
    }
    if(!defined($JR->{mpi}{data_rx}{$irank}{$jrank})) {
     $JR->{mpi}{data_rx}{$irank}{$jrank} = 0;
    }
    if(!defined($JR->{mpi}{nmsg_tx}{$irank}{$jrank})) {
     $JR->{mpi}{nmsg_tx}{$irank}{$jrank} = 0;
    }
    if(!defined($JR->{mpi}{nmsg_rx}{$irank}{$jrank})) {
     $JR->{mpi}{nmsg_rx}{$irank}{$jrank} = 0;
    }
    print FH "$rtag $irank $jrank $data_ij $JR->{mpi}{data_tx}{$irank}{$jrank} $JR->{mpi}{data_rx}{$irank}{$jrank} $JR->{mpi}{nmsg_tx}{$irank}{$jrank} $JR->{mpi}{nmsg_rx}{$irank}{$jrank}\n";
   }
  }
 }
 close(FH);
  
 open(FH,">$html_dir/map_adjacency$tag.txt") or die("Can't open file\n");

 print FH "# irank : nadj nsend nrecv : orank(s)\n";
 foreach $irank (sort numy keys %{$J->{task}} ) {
  $NL = ""; $NN = 0; $NS=0; $NR=0;
  foreach $jrank (sort numy keys %{$J->{task}} ) {
   $data_ij = 0;
   if(defined($JR->{mpi}{data_tx}{$irank}{$jrank})) {
    $data_ij += $JR->{mpi}{data_tx}{$irank}{$jrank};
   }
   if(defined($JR->{mpi}{data_rx}{$irank}{$jrank})) {
    $data_ij += $JR->{mpi}{data_rx}{$irank}{$jrank};
   }
   if($data_ij > 0) {
    $NL = $NL."$jrank ";
    $NN ++;
   }
   if( $JR->{mpi}{data_tx}{$irank}{$jrank} ) {
    $NS ++;
   }
   if( $JR->{mpi}{data_rx}{$irank}{$jrank} ) {
    $NR ++;
   }
   
  }
  if($NL cmp "") {
   print FH "$irank : $NN $NS $NR : $NL\n";
  }
 }
 close(FH);

###
# }
###
 $TINT2 = time();
 printf("#  topo_tables    = %d sec\n", $TINT2-$TINT1, $tag);

$TINT1 = time();
###
# MPI topology : data flow {
###
 
 $i = 0;
 $ntpo = $J->{ntasks} + 1;
 
 $sw = 6;
 $sh = 6;
 @flows = ("tot", "send", "recv");

 foreach $flow (@flows) {

 $data_max = -1.0;
 $data_tot =  0.0;
 $nmsg_max = -1.0;
 $nmsg_tot =  0.0;
 $time_max = -1.0;
 $time_tot =  0.0;
 foreach $irank (sort keys %{$J->{task}} ) {
  foreach $jrank (sort keys %{$J->{task}} ) {
   if($flow eq "tot") {
  
   $data_ij = $JR->{mpi}{data_tx}{$irank}{$jrank} + $JR->{mpi}{data_rx}{$irank}{$jrank};
   $nmsg_ij = $JR->{mpi}{nmsg_tx}{$irank}{$jrank} + $JR->{mpi}{nmsg_rx}{$irank}{$jrank};
   }
   if($flow eq "send") {
   $data_ij = $JR->{mpi}{data_tx}{$irank}{$jrank};
   $nmsg_ij = $JR->{mpi}{nmsg_tx}{$irank}{$jrank};
   }
   if($flow eq "recv") {
   $data_ij = $JR->{mpi}{data_rx}{$irank}{$jrank};
   $nmsg_ij = $JR->{mpi}{nmsg_rx}{$irank}{$jrank};
   }
   if($data_ij > $data_max) {  $data_max = $data_ij; }
   if($nmsg_ij > $nmsg_max) {  $nmsg_max = $nmsg_ij; }
   $data_tot += $data_ij;
   $nmsg_tot += $nmsg_ij;
  }
 }
 
# $data_tot = $data_tot/2.0;
 
  open(FH,">$PLPRE/mpi_topo_data_$flow$tag") or die("Can't open file\n");

 if($data_max > 0) {
 print FH<<EOF;
#proc areadef
  rectangle: 1 1 $sw $sh
  frame: width=0.5 color=0.3
  xrange: -1 $J->{ntasks}
  yrange: -1 $J->{ntasks}
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.stubrange: 0 $ntmo
  yaxis.stubrange: 0 $ntmo
  xaxis.stubvert: yes
  xaxis.label: MPI_Rank
  yaxis.label: MPI_Rank
 
EOF
 foreach $irank (sort numy keys %{$J->{task}} ) {
  foreach $jrank (sort numy keys %{$J->{task}} ) {
   $data_ij = $JR->{mpi}{data_tx}{$irank}{$jrank} + $JR->{mpi}{data_rx}{$irank}{$jrank};
    printf FH "#proc rect\n rectangle: %f(s) %f(s) %f(s) %f(s)\n color: gray(%.2f)\n\n", $irank-0.5, $jrank-0.5, $irank+0.5,$jrank+0.5, 1.0-$data_ij/$data_max;
   }
  }
 
 print FH "\n\n";
 for (my $p = 0.0; $p <= 1.0; $p+= 0.2) {
 printf FH "#proc legendentry:\nsampletype: symbol\ndetails: style=outline fillcolor=gray(%.2f) shape=square linecolor=black\n label: %.8f MB\n" , $p,(1.0-$p)*$data_max/(1024*1024);
  }
 print FH <<EOF;
 
#proc legend
location: max+0.5 max-0.5
 
EOF
 } else {
 
print FH<<EOF;
#proc areadef
  rectangle: 0 0 3.5 3
  xrange: 0 1
  yrange: 0 2
                                                                                
#proc annotate
  location: 1 3
  textdetails: size=32 color=black
  backcolor: white
  text: None
EOF
 }
 
 close(FH);
 
 system("$PLOTICUS $PLPRE/mpi_topo_data_$flow$tag -$gfmt -o $IMPRE/mpi_topo_data_$flow$tag.$gfmt");
 
  } # next flow

###
# }
###
 $TINT2 = time();
 printf("#  topo_data      = %d sec\n", $TINT2-$TINT1,$tag);
 
$TINT1 = time();
###
# MPI topology : time {
###
 
 $i = 0;
 $ntpo = $J->{ntasks} + 1;
 
 $sw = 6;
 $sh = 6;
 
 $time_max = -1.0;
 foreach $irank (sort keys %{$J->{task}} ) {
  foreach $jrank (sort keys %{$J->{task}} ) {
   $time_ij = $JR->{mpi}{time}{$irank}{$jrank};
#   $time_ij = $JR->{mpi}{time_tx}{$irank}{$jrank} + $JR->{mpi}{time_rx}{$irank}{$jrank};
   if($time_ij > $time_max) {  $time_max = $time_ij; }
  }
 }
# $time_max = $time_max/2.0;
 
 open(FH,"> $PLPRE/mpi_topo_time$tag") or die("Can't open file\n");
 if($time_max > 0) {
 print FH<<EOF;
#proc areadef
  rectangle: 1 1 $sw $sh
  frame: width=0.5 color=0.3
  xrange: -1 $J->{ntasks}
  yrange: -1 $J->{ntasks}
  xaxis.stubs: inc
  yaxis.stubs: inc
  xaxis.stubrange: 0 $ntmo
  yaxis.stubrange: 0 $ntmo
  xaxis.stubvert: yes
  xaxis.label: MPI_Rank
  yaxis.label: MPI_Rank
 
EOF
 
#print Dumper($JR->{mpi});

 foreach $irank (sort keys %{$J->{task}} ) {
  foreach $jrank (sort keys %{$J->{task}} ) {
   $time_ij = $JR->{mpi}{time}{$irank}{$jrank};
   if($time_ij > 0) {
    printf FH "#proc rect\n rectangle: %f(s) %f(s) %f(s) %f(s)\n color: gray(%.2f)\n\n", $irank-0.5, $jrank-0.5, $irank+0.5,$jrank+0.5, $time_ij/$time_max;
   }
  }
 }
 
 print FH "\n\n";
 for (my $p = 0.0; $p <= 1.0; $p+= 0.2) {
 printf FH "#proc legendentry:\nsampletype: symbol\ndetails: style=outline fillcolor=gray(%.2f) shape=square linecolor=black\n label: %.3e sec\n" , $p,(1.0-$p)*$time_max/(1024*1024);
  }
 print FH <<EOF;
 
#proc legend
location: max+0.5 max-0.5
 
EOF
 } else {
 
print FH<<EOF;
#proc areadef
  rectangle: 0 0 3.5 3
  xrange: 0 1
  yrange: 0 2
                                                                                
#proc annotate
  location: 1 3
  textdetails: size=32 color=black
  backcolor: white
  text: None
EOF
 }
 
 
 close(FH);
 
 system("$PLOTICUS $PLPRE/mpi_topo_time$tag -$gfmt -o $IMPRE/mpi_topo_time$tag.$gfmt");
 
 
###
# }
###
 $TINT2 = time();
 printf("#  topo_time      = %d sec\n",$TINT2-$TINT1,$tag);
 
} # if ($J->{ntasks} => $topology_tasks ) 


###
# }
###

###
# HTML generation {
###
 open(FH, $fname);

print FH<<EOF;

<html>
<title> IPM profile for $htag </title>
<head>
<STYLE TYPE="text/css">
#unreadable { font-size: 1pt; }
.example { font-family: Garamond, Times, serif; }
</STYLE>
</head>
<body>


<table border=1 borderwidth=0 width=100% cellpadding=0 cellspacing=0>
<tr><td width=25% valign="top" align="left" bgcolor="lightblue">
<table  border=0 borderwidth=0 width=100% cellpadding=0 cellspacing=0>
<tr><td width="100%" height="100%" valign="top" align="left" bgcolor="lightblue">
<a name="top">
<b> $htag </b><br>
</a>
</td></tr>
<tr><td width=100% valign="top" align="left" bgcolor="lightblue">
<font size=-2>
<ul>
<li> <a href="#lb">Load Balance</a>
<li> <a href="#cb">Communication Balance</a>
<li> <a href="#bs">Message Buffer Sizes</a>
<li> <a href="#ct">Communication Topology</a>
<li> <a href="#st">Switch Traffic</a>
<li> <a href="#mu">Memmory Usage</a>
<li> <a href="exec.html">Executable Info</a>
<li> <a href="hostlist.html">Host List</a>
<li> <a href="env.html">Environment</a>
<li> <a href="dev.html">Developer Info</a>
</ul>
</font>
</td></tr>
<tr><td width=100% valign="bottom" align="left" bgcolor="lightblue">
<center>
	<a href="http://ipm-hpc.sf.net/">
	<img valign="bottom" border="0" alt="powered by IPM" src="http://www.nersc.gov/projects/ipm/ipm_powered.png">
	</a>
</center>
</td></tr>
EOF
 if($report_all == 0) {
print FH<<EOF;
<tr><td><a href="index.html"> back </a> </td></tr>
EOF
 }
print FH<<EOF;
</table>
</td>

<td width=75% valign="top">
<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>
<tr>
 <td width=100% colspan=2 bgcolor="lightblue" valign="top"> 
 command: $J->{cmdline}  
 </td>
</tr> 
EOF

if($report_all == 1) {
@tmp = (
["codename:", "$J->{code}", "state:", "$J->{app_state}"],
["username:", "$J->{username}", "group:", "$J->{groupname}"],
["host:", "$J->{hostname} ($J->{mach_info})", "mpi_tasks:", "$J->{ntasks} on $J->{nhosts} hosts"],
["start:", "$J->{start_date_buf}", "wallclock:", "$J->{wtime_max} sec"],
["stop:", "$J->{final_date_buf}", "%comm:", "$J->{pcomm}"],
["total memory:", "$J->{gbyte} gbytes", "total gflop/sec:", "$J->{gflops}"],
["switch(send):", "$J->{gbyte_tx} gbytes", "switch(recv):", "$J->{gbyte_rx} gbytes"]
);
} else {
@tmp = (
["region:", "$ireg", "state:", "$J->{app_state}"],
["username:", "$J->{username}", "group:", "$J->{groupname}"],
["host:", "$J->{hostname} ($J->{mach_info})", "mpi_tasks:", "$JR->{ntasks} on $J->{nhosts} hosts"],
["wallclock:", "$JR->{wtime_max} sec", "#exits:", "$JR->{nexits}/$JR->{ntasks}"], 
["%comm:", "$JR->{pcomm}", "gflop/sec:", "$JR->{gflops}"]
);
}
	 
foreach $i (@tmp) {
print FH<<EOF;
<tr>
 <td width=50%> 
 <table width=100%> <tr>
 <td width=50% align=left> @{$i}[0] </td> <td width=50% align=right> @{$i}[1] </td>
 </tr> </table>
 </td>

 <td width=50%> 
 <table width=100%> <tr>
 <td width=50% align=left> @{$i}[2] </td> <td width=50% align=right> @{$i}[3] </td>
 </tr> </table>
 </td>
</tr>
EOF
}
@tmp = ();


print FH<<EOF;
</table>
</font>
</td>
</tr>
</table>

EOF

if($report_all == 1  && $J->{nregion} > 1) {
print FH<<EOF;

<table border=1 borderwidth=0 width=100% cellpadding=0 cellspacing=0>
<tr> <th colspan=6 valign="top" bgcolor="lightblue"> <H3> Regions </H3> </th> </tr>
<tr>
 <th valign=top bgcolor="lightblue"> <B>Label </B> </th>
 <th valign=top bgcolor="lightblue"> <B>Ntasks </B> </th>
 <th valign=top bgcolor="lightblue"> <B>&lt;MPI sec&gt; </B> </th>
 <th valign=top bgcolor="lightblue"> <B>&lt;Wall sec&gt; </B> </th>
 <th valign=top bgcolor="lightblue"> <B>%Wall</B> </th>
 <th valign=top bgcolor="lightblue"> <B>[gflop/sec]</B> </th>
</tr>
EOF

foreach $ireg (reverse(sort regbywtime keys %{$J->{region_name}})) {
   $JR = \%{$J->{region}{$ireg}};
printf FH "<tr><td><a href=\"index_$ireg.html\">%-21.21s</a> </td><td align=right> %6d  </td><td align=right> %13.4f </td><td align=right> %13.4f</td> <td align=right> %.2f </td> <td align=right> %.4e</td></tr>\n",
	 $ireg,
	 $JR->{ntasks},
	 $JR->{mtime}/$JR->{ntasks},
	 $JR->{wtime}/$JR->{ntasks},
	 100*$JR->{wtime}/($J->{ntasks}*$J->{jtime}),
	$JR->{gflops}
}
}

print FH<<EOF;
</table>

<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>
<tr width=100%>
<td width=50% valign=top>
<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>
<tr>
 <th valign=top colspan=3 bgcolor="lightblue"> <H3> Computation </H3> </th> </tr>
<tr>
 <th valign=top bgcolor="lightblue"> Event </th>
 <th valign=top bgcolor="lightblue"> Count </th>
 <th valign=top bgcolor="lightblue"> Pop </th>
</tr>
EOF

foreach $icounter (sort keys %{$JR->{counter}} ) {
 if($J->{counter}{$icounter}{pop} == $JR->{ntasks}) {
  $popstr = " <td align=center>*</td> ";
 } else {
  $popstr =" <td align=right> $JR->{counter}{$icounter}{pop} </td>";
 }
 print FH "<tr><td> $icounter </td><td align=right> $JR->{counter}{$icounter}{count} </td>$popstr</tr>\n";
}
  

print FH<<EOF;
</table>
</td>
<td width=50% valign=top>
<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>
<tr> <th bgcolor="lightblue"> <H3> Communication </H3> </th> </tr>
<tr> <th bgcolor="lightblue"> % of MPI Time </th> </tr>
<tr>
<td>
<center>
<img src="img/mpi_pie$tag.$gfmt">
</center>
</td>
</tr>
</table>
</td>
</tr>
</table>

<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>
<tr>
<th align=left bgcolor=lightblue colspan=5> HPM Counter Statistics </th>
</th>
</tr>
<tr>
<th align=left bgcolor=lightblue> Event </th>
<th align=center bgcolor=lightblue> Ntasks </th>
<th align=right bgcolor=lightblue> Avg </th>
<th align=right bgcolor=lightblue> Min(rank) </th>
<th align=right bgcolor=lightblue> Max(rank) </th>
</tr>
EOF

foreach $icounter (sort keys %{$JR->{counter}} ) {
 print FH "<tr><td> $icounter </td>\n";
 if($JR->{counter}{$icounter}{pop} == $JR->{ntasks}) {
  print FH " <td align=center>*</td> ";
 } else {
  print FH " <td align=right> $JR->{counter}{$icounter}{pop} </td>";
 }
 printf FH "<td align=right> %.2f </td>\n", $JR->{counter}{$icounter}{count}/$JR->{counter}{$icounter}{pop};
 print FH "<td align=right> ".$JR->{counter}{$icounter}{count_min}." (".$JR->{counter}{$icounter}{count_minr}.") </td> \n";
 print FH "<td align=right> ".$JR->{counter}{$icounter}{count_max}." (".$JR->{counter}{$icounter}{count_maxr}.") </td></tr> \n";
}
  
print FH<<EOF;
</table>

<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>
<tr>
<th align=left bgcolor=lightblue colspan=8>
 Communication Event Statistics
EOF
 if($JR->{mtime} == $JR->{hash_time}) {
  print FH "(100% detail)";
 } else {
  printf FH "(%.2f%% detail, %.4e error)", 100*$JR->{hash_time}/$JR->{mtime}, $JR->{mtime}-$JR->{hash_time};
 }
print FH<<EOF;
 </th>
</tr>
<tr>
<th align=left bgcolor=lightblue> &nbsp; </th>
<th align=left bgcolor=lightblue> Buffer Size </th>
<th align=left bgcolor=lightblue> Ncalls </th>
<th align=left bgcolor=lightblue> Total Time </th>
<th align=left bgcolor=lightblue> Min Time </th>
<th align=left bgcolor=lightblue> Max Time </th>
<th align=left bgcolor=lightblue> %MPI </th>
<th align=left bgcolor=lightblue> %Wall </th>
</tr>
EOF
 
 foreach $ikey (reverse(sort jcallsizebyttot keys %{$JR->{mpi}{call_size}})) {
  ($icall,$ibyte) = split('!',$ikey);
  $pct_mpi =  100 * ( $JR->{mpi}{call_size}{$ikey}{ttot} / $JR->{mtime} );
  $pct_wall =  100 * ( $JR->{mpi}{call_size}{$ikey}{ttot} / ( $JR->{ntasks} * $JR->{wtime_max}) );
 
   
  if($pct_wall < 0.01) {next;}
 
  printf FH "<tr><td align=left>%s</td><td align=right> %d </td><td align=right> %d </td><td align=right> %.3f </td><td align=right> %.3e </td><td align=right> %.3e </td><td align=right> %.2f </td><td align=right> %.2f </td> </tr> \n", $icall, $ibyte, $JR->{mpi}{call_size}{$ikey}{count}, $JR->{mpi}{call_size}{$ikey}{ttot}, $JR->{mpi}{call_size}{$ikey}{tmin},$JR->{mpi}{call_size}{$ikey}{tmax}, $pct_mpi , $pct_wall;
 }
                                                                                
print FH<<EOF; 

</table>


<table border=1 borderwidth=1 width=100% cellpadding=0 cellspacing=0>

<tr>
<th align=left bgcolor=lightblue>
<a name="lb">
 Load balance by task: HPM counters
</a>
 </th>
</th>
</tr>
<tr>
<td>
<img src="img/load_hpm_all$tag.$gfmt">
</td>
</tr>
<tr>
<td>
<a href="img/load_hpm_rank$tag.$gfmt"> by MPI rank</a>, 
<a href="img/load_hpm_mtime$tag.$gfmt"> by MPI time</a>
</td>
</tr>

<tr>
<th align=left bgcolor=lightblue> Load balance by task: memory, flops, timings </th>
</th>
</tr>
<tr>
<td>
<img src="img/load_multi$tag.$gfmt">
</td>
</tr>

<tr>
<td>
<a href="img/load_multi_rank$tag.$gfmt"> by MPI rank</a>, 
<a href="img/load_multi_mtime$tag.$gfmt"> by MPI time</a>
</td>
</tr>

<tr>
<th align=left bgcolor=lightblue>
<a name="cb">
 Communication balance by task (sorted by MPI time)
</a>
</th>
</tr>
<tr>
<td>
<img src="img/mpi_stack_bymtime$tag.$gfmt">
</td>
</tr>

<tr>
<td>
<a href="img/mpi_stack_byrank$tag.$gfmt">by MPI rank </a> , 
<a href="img/time_stack_bymtime$tag.$gfmt"> time detail by MPI time </a>,
<a href="img/time_stack_byrank$tag.$gfmt"> time detail by rank </a>,
<a href="map_calls.txt">call list</a> 
</td>
</tr>

<tr>
<th align=left bgcolor=lightblue>
<a name="bs"> Message Buffer Size Distributions: time </a>
</th>
</th>
</tr>
<tr>
<td>
<img src="img/mpi_buff_time$tag.$gfmt">
</td>
</tr>
<tr>
<td>
<center>
<a href="img/mpi_buff_time_abs$tag.$gfmt">cumulative values</a>,
<a href="img/mpi_buff_time_hist$tag.$gfmt">values</a>
</center>
</td>
</tr>


<tr>
<th align=left bgcolor=lightblue> Message Buffer Size Distributions: Ncalls </th>
</th>
</tr>
<tr>
<td>
<img src="img/mpi_buff_call$tag.$gfmt">
</td>
</tr>
<tr>
<td>
<center>
<a href="img/mpi_buff_call_abs$tag.$gfmt">cumulative values</a>,
<a href="img/mpi_buff_call_hist$tag.$gfmt">values</a>
</center>
</td>
</tr>
<tr>


<!--
<tr>
<th align=left bgcolor=lightblue> Message Buffer Size Distributions: data volume </th>
</th>
</tr>
<tr>
<td>
<img src="img/mpi_buff_data$tag.$gfmt">
</td>
</tr>
<tr>
<td>
<center>
<a href="img/mpi_buff_data_abs$tag.$gfmt">cumulative values</a>,
<a href="img/mpi_buff_data_hist$tag.$gfmt">values</a>
</center>
</td>
</tr>
<tr>
-->

<tr>
<th align=left bgcolor=lightblue>
<a name="ct">
 Communication Topology : point to point data flow
</a>
 </th>
</tr>
<tr>
<td>
<img src="img/mpi_topo_data_tot$tag.$gfmt">
</td>
</tr>
<tr>
<td>
<center>
<a href="img/mpi_topo_data_send$tag.$gfmt">data sent </a>,
<a href="img/mpi_topo_data_recv$tag.$gfmt">data recv </a>,
<a href="img/mpi_topo_time$tag.$gfmt">time spent </a>,
<a href="map_data$tag.txt">map_data file</a>
<a href="map_adjacency$tag.txt">map_adjacency file</a>
</center>
</td>
</tr>

EOF
if($report_all == 1) {
print FH <<EOF;
<tr> 
<th align=left bgcolor=lightblue>
<a name="st" > Switch Traffic (volume by node) </a>
</th>
</tr>
<tr> <td> <center><img src="img/switch_stack_bydata.$gfmt"></center> </td> </tr>

<tr> <th align=left bgcolor=lightblue>
<a name="mu"> Memory usage by node </a>
</th> </tr>
<tr> <td> <center><img src="img/mem_stack_bymem$tag.$gfmt"></center> </td> </tr>

EOF
}

print FH <<EOF;

</table>

EOF
 if($report_all == 0) {
print FH<<EOF;
<a href="index.html"> back </a>
EOF
 }

print FH<<EOF;
</body>
</html>
EOF

###
# }
###

 close(FH);
 return;
}
