###############################################################################
# 
# Developed with Kate
#
#  (c) 2017-2018 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
#  All rights reserved
#
#   Special thanks goes to:
#       - Dusty Wilson      Inspiration and parts of Code
#                           http://search.cpan.org/~wilsond/Linux-APT-0.02/lib/Linux/APT.pm
#
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
# $Id$
#
###############################################################################

        
        


package main;

my $missingModul = "";

use strict;
use warnings;
use POSIX;

use Data::Dumper;      #only for Debugging

eval "use JSON;1" or $missingModul .= "JSON ";




my $version = "0.0.50";




# Declare functions
sub AptToDate_Initialize($);
sub AptToDate_Define($$);
sub AptToDate_Undef($$);
sub AptToDate_Attr(@);
sub AptToDate_Set($$@);
sub AptToDate_Get($$@);
sub AptToDate_Notify($$);
sub AptToDate_ProcessUpdateTimer($);
sub AptToDate_CleanSubprocess($);
sub AptToDate_AsynchronousExecuteAptGetCommand($);
sub AptToDate_OnRun();
sub AptToDate_PollChild($);
sub AptToDate_ExecuteAptGetCommand($);
sub AptToDate_GetDistribution();
sub AptToDate_AptUpdate($);
sub AptToDate_AptUpgradeList($);
sub AptToDate_AptToUpgrade($);
sub AptToDate_PreProcessing($$);
sub AptToDate_WriteReadings($$);
sub AptToDate_CreateUpgradeList($$);
sub AptToDate_CreateWarningList($);
sub AptToDate_CreateErrorList($);
sub AptToDate_ToDay();





my %regex = (   'en' => { 'update'    => '^Reading package lists...$', 'upgrade'    => '^Unpacking (\S+)\s\((\S+)\)\s+over\s+\((\S+)\)'},
                'de' => { 'update'    => '^Paketlisten werden gelesen...$' ,'upgrade'   => '^Entpacken von (\S+)\s\((\S+)\)\s+über\s+\((\S+)\)'}
);




sub AptToDate_Initialize($) {

    my ($hash) = @_;

    $hash->{SetFn}      = "AptToDate_Set";
    $hash->{GetFn}      = "AptToDate_Get";
    $hash->{DefFn}      = "AptToDate_Define";
    $hash->{NotifyFn}   = "AptToDate_Notify";
    $hash->{UndefFn}    = "AptToDate_Undef";
    $hash->{AttrFn}     = "AptToDate_Attr";
    $hash->{AttrList}   = "disable:1 ".
                            "disabledForIntervals ".
                            $readingFnAttributes;


    foreach my $d(sort keys %{$modules{AptToDate}{defptr}}) {
        my $hash = $modules{AptToDate}{defptr}{$d};
        $hash->{VERSION} 	= $version;
    }
}

sub AptToDate_Define($$) {

    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );
    
    return "too few parameters: define <name> AptToDate <HOST>" if( @a != 3 );
    return "Cannot define AptToDate device. Perl modul ${missingModul}is missing." if ( $missingModul );
    

    my $name            = $a[0];
    my $host            = $a[2];

    $hash->{VERSION}    = $version;
    $hash->{HOST}       = $host;
    $hash->{NOTIFYDEV}  = "global,$name";
        
    
    readingsSingleUpdate($hash,"state","initialized", 1) if( ReadingsVal($name,'state','none') ne 'none');
    CommandAttr(undef,$name . ' room AptToDate') if( AttrVal($name,'room','none') eq 'none' );
    
    Log3 $name, 3, "AptToDate ($name) - defined";
    
    $modules{AptToDate}{defptr}{$hash->{HOST}} = $hash;
    
    return undef;
}

sub AptToDate_Undef($$) {

    my ($hash,$arg) = @_;
    
    
    my $name = $hash->{NAME};

    if(exists($hash->{".fhem"}{subprocess})) {
        my $subprocess  = $hash->{".fhem"}{subprocess};
        $subprocess->terminate();
        $subprocess->wait();
    }
    
    delete($modules{AptToDate}{defptr}{$hash->{HOST}});
    Log3 $name, 3, "Sub AptToDate_Undef ($name) - delete device $name";
    return undef;
}

sub AptToDate_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash                                = $defs{$name};


    if( $attrName eq "disable" ) {
        if( $cmd eq "set" and $attrVal eq "1" ) {
            RemoveInternalTimer($hash);
            
            readingsSingleUpdate ( $hash, "state", "disabled", 1 );
            Log3 $name, 3, "AptToDate ($name) - disabled";
        }

        elsif( $cmd eq "del" ) {
            Log3 $name, 3, "AptToDate ($name) - enabled";
        }
    }
    
    elsif( $attrName eq "disabledForIntervals" ) {
        if( $cmd eq "set" ) {
            return "check disabledForIntervals Syntax HH:MM-HH:MM or 'HH:MM-HH:MM HH:MM-HH:MM ...'"
            unless($attrVal =~ /^((\d{2}:\d{2})-(\d{2}:\d{2})\s?)+$/);
            Log3 $name, 3, "AptToDate ($name) - disabledForIntervals";
            readingsSingleUpdate ( $hash, "state", "disabled", 1 );
        }
        
        elsif( $cmd eq "del" ) {
            Log3 $name, 3, "AptToDate ($name) - enabled";
            readingsSingleUpdate ( $hash, "state", "active", 1 );
        }
    }
    
    return undef;
}

sub AptToDate_Notify($$) {

    my ($hash,$dev) = @_;
    my $name = $hash->{NAME};
    return if (IsDisabled($name));
    
    my $devname = $dev->{NAME};
    my $devtype = $dev->{TYPE};
    my $events = deviceEvents($dev,1);
    return if (!$events);

    Log3 $name, 5, "AptToDate ($name) - Notify: ".Dumper $events;       # mit Dumper


    if( ((grep /^DEFINED.$name$/,@{$events} or grep /^DELETEATTR.$name.disable$/,@{$events}
            or grep /^ATTR.$name.disable.0$/,@{$events})
            and $devname eq 'global' and $init_done)
            or ((grep /^INITIALIZED$/,@{$events}
            or grep /^REREADCFG$/,@{$events}
            or grep /^MODIFIED.$name$/,@{$events}) and $devname eq 'global')
            or grep /^os-release_language:.(de|en)$/,@{$events} ) {

        if( ReadingsVal($name,'os-release_language','none') ne 'none' ) {
            AptToDate_ProcessUpdateTimer($hash);
        
        } else {
            $hash->{".fhem"}{aptget}{cmd}   = 'getDistribution';
            AptToDate_AsynchronousExecuteAptGetCommand($hash);
        }
    }

    if( $devname eq $name and (grep /^repoSync:.fetched.done$/,@{$events}
                                or grep /^toUpgrade:.successful$/,@{$events}) ) {
        $hash->{".fhem"}{aptget}{cmd}   = 'getUpdateList';
        AptToDate_AsynchronousExecuteAptGetCommand($hash);
    }

    return;
}

sub AptToDate_Set($$@) {
    
    my ($hash, $name, @aa)  = @_;
    
    
    my ($cmd, @args)        = @aa;

    if( $cmd eq 'repoSync' ) {
        return "usage: $cmd" if( @args != 0 );
        
        $hash->{".fhem"}{aptget}{cmd}   = $cmd;
        
    } elsif( $cmd eq 'toUpgrade' ) {
        return "usage: $cmd" if( @args != 0 );
        
        $hash->{".fhem"}{aptget}{cmd}   = $cmd;
    
    } else {
        my $list = "repoSync:noArg";
        $list .= " toUpgrade:noArg" if( defined($hash->{".fhem"}{aptget}{packages}) and scalar keys %{$hash->{".fhem"}{aptget}{packages}} > 0 );
        
        return "Unknown argument $cmd, choose one of $list";
    }
    
    AptToDate_AsynchronousExecuteAptGetCommand($hash);
    
    return undef;
}

sub AptToDate_Get($$@) {
    
    my ($hash, $name, @aa)  = @_;
    
    
    my ($cmd, @args)        = @aa;

    if( $cmd eq 'showUpgradeList' ) {
        return "usage: $cmd" if( @args != 0 );

        my $ret = AptToDate_CreateUpgradeList($hash,$cmd);
        return $ret;
        
    } elsif( $cmd eq 'showUpdatedList' ) {
        return "usage: $cmd" if( @args != 0 );

        my $ret = AptToDate_CreateUpgradeList($hash,$cmd);
        return $ret;
        
    } elsif( $cmd eq 'showWarningList' ) {
        return "usage: $cmd" if( @args != 0 );

        my $ret = AptToDate_CreateWarningList($hash);
        return $ret;
        
    } elsif( $cmd eq 'showErrorList' ) {
        return "usage: $cmd" if( @args != 0 );

        my $ret = AptToDate_CreateErrorList($hash);
        return $ret;

    } else {
        my $list = "";
        $list .= " showUpgradeList:noArg" if( defined($hash->{".fhem"}{aptget}{packages}) and scalar keys %{$hash->{".fhem"}{aptget}{packages}} > 0 );
        $list .= " showUpdatedList:noArg" if( defined($hash->{".fhem"}{aptget}{updatedpackages}) and scalar keys %{$hash->{".fhem"}{aptget}{updatedpackages}} > 0 );
        $list .= " showWarningList:noArg" if( defined($hash->{".fhem"}{aptget}{'warnings'}) and scalar @{$hash->{".fhem"}{aptget}{'warnings'}} > 0 );
        $list .= " showErrorList:noArg" if( defined($hash->{".fhem"}{aptget}{'errors'}) and scalar @{$hash->{".fhem"}{aptget}{'errors'}} > 0 );

        return "Unknown argument $cmd, choose one of $list";
    }
}

###################################
sub AptToDate_ProcessUpdateTimer($) {

    my $hash    = shift;
    
    
    my $name =  $hash->{NAME};
    
    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday()+14400, "AptToDate_ProcessUpdateTimer", $hash,0 );
    Log3 $name, 4, "AptToDate ($name) - stateRequestTimer: Call Request Timer";

    if( !IsDisabled($name) ) {
        if(exists($hash->{".fhem"}{subprocess})) {
            Log3 $name, 2, "AptToDate ($name) - update in progress, process aborted.";
            return 0;
        }
        
        readingsSingleUpdate($hash,"state","ready", 1) if( ReadingsVal($name,'state','none') eq 'none' or ReadingsVal($name,'state','none') eq 'initialized' );
        
        if( AptToDate_ToDay() ne (split(' ',ReadingsTimestamp($name,'repoSync','1970-01-01')))[0]) {
            $hash->{".fhem"}{aptget}{cmd}   = 'repoSync';
            AptToDate_AsynchronousExecuteAptGetCommand($hash);
        }
    }
}

sub AptToDate_CleanSubprocess($) {

    my $hash    = shift;
    
    
    my $name    = $hash->{NAME};

    delete($hash->{".fhem"}{subprocess});
    Log3 $name, 4, "AptToDate ($name) - clean Subprocess";
}


use constant POLLINTERVAL => 1;

sub AptToDate_AsynchronousExecuteAptGetCommand($) {

    require "SubProcess.pm";
    my ($hash)                      = shift;
    
    
    my $name                        = $hash->{NAME};
    $hash->{".fhem"}{aptget}{lang}  = ReadingsVal($name,'os-release_language','none');

    my $subprocess                  = SubProcess->new({ onRun => \&AptToDate_OnRun });
    $subprocess->{aptget}           = $hash->{".fhem"}{aptget};
    my $pid                         = $subprocess->run();

    readingsSingleUpdate($hash,'state',$hash->{".fhem"}{aptget}{cmd}.' in progress', 1);
    
    
    if(!defined($pid)) {
        Log3 $name, 1, "AptToDate ($name) - Cannot execute apt-get command asynchronously";

        AptToDate_CleanSubprocess($hash);
        readingsSingleUpdate($hash,'state','Cannot execute apt-get command asynchronously', 1);
        return undef;
    }

    Log3 $name, 4, "AptToDate ($name) - execute apt-get command asynchronously (PID= $pid)";
    
    $hash->{".fhem"}{subprocess}    = $subprocess;
    
    InternalTimer(gettimeofday()+POLLINTERVAL, "AptToDate_PollChild", $hash, 0);
    Log3 $hash, 4, "AptToDate ($name) - control passed back to main loop.";
}

sub AptToDate_PollChild($) {

    my $hash        = shift;
    
    
    my $name        = $hash->{NAME};
    my $subprocess  = $hash->{".fhem"}{subprocess};
    my $json        = $subprocess->readFromChild();
    
    if(!defined($json)) {
        Log3 $name, 4, "AptToDate ($name) - still waiting (". $subprocess->{lasterror} .").";
        InternalTimer(gettimeofday()+POLLINTERVAL, "AptToDate_PollChild", $hash, 0);
        return;
    } else {
        Log3 $name, 4, "AptToDate ($name) - got result from asynchronous parsing.";
        $subprocess->wait();
        Log3 $name, 4, "AptToDate ($name) - asynchronous finished.";
        
        AptToDate_CleanSubprocess($hash);
        AptToDate_PreProcessing($hash,$json);
    }
}

######################################
# Begin Childprozess
######################################

sub AptToDate_OnRun() {

    my $subprocess  = shift;
    
    
    my $response    = AptToDate_ExecuteAptGetCommand($subprocess->{aptget});
    
    my $json        = eval{encode_json($response)};
    if($@){
        Log3 'AptToDate OnRun', 3, "AptToDate - JSON error: $@";
        $json   = '{"jsonerror":"$@"}';
    }
    
    $subprocess->writeToParent($json);
}

sub AptToDate_ExecuteAptGetCommand($) {

    my $aptget              = shift;
    

    my $apt                 = { 'aptget' => 'sudo apt-get' };
    $apt->{lang}            = $aptget->{lang};
    my $response;
    
    if( $aptget->{cmd} eq 'repoSync' ) {
        $response    = AptToDate_AptUpdate($apt);
    } elsif( $aptget->{cmd} eq 'getUpdateList' ) {
        $response    = AptToDate_AptUpgradeList($apt);
    } elsif( $aptget->{cmd} eq 'getDistribution' ) {
        $response    = AptToDate_GetDistribution();
    } elsif( $aptget->{cmd} eq 'toUpgrade' ) {
        $response    = AptToDate_AptToUpgrade($apt);
    }

    return $response;
}

sub AptToDate_GetDistribution() {

    my $update  = {};


    if(open(DISTRI, "</etc/os-release")) {
        while (my $line = <DISTRI>) {
            chomp($line);
            Log3 'AptToDate', 4, "Sub AptToDate_GetDistribution - $line";
            if($line =~ m#^(.*)="?(.*)"$#i or $line =~ m#^(.*)=([a-z]+)$#i) {
                $update->{'os-release'}{'os-release_'.$1}   = $2;
                Log3 'Update', 4, "Distribution Daten erhalten"
            }
        }
        
        close(APT);
    } else {
        die Log3 'Update', 2, "Couldn't use APT: $!";
        #die "Couldn't use APT: $!\n";
        $update->{error}    = 'Couldn\'t use APT: '.$;
    }
    
    if(open(APT, "echo n | locale 2>&1 |")) {
        while(my $line = <APT>) {
        
            chomp($line);
            Log3 'AptToDate', 4, "Sub AptToDate_GetDistribution - $line";
            if($line =~ m#^LANG=([a-z]+).*$#) {
                $update->{'os-release'}{'os-release_language'}  = $1;
                Log3 'Update', 4, "Language Daten erhalten"
            }
        }
        
        close(APT);
    } else {
        die Log3 'Update', 2, "Couldn't use APT: $!";
        #die "Couldn't use APT: $!\n";
        $update->{error}    = 'Couldn\'t use APT: '.$;
    }

    return $update;
}

sub AptToDate_AptUpdate($) {

    my $apt     = shift;
    
    
    my $update  = {};

    if(open(APT, "echo n | $apt->{aptget} -q update 2>&1 | ")) {
        while (my $line = <APT>) {
            chomp($line);
            Log3 'AptToDate', 4, "Sub AptToDate_AptUpdate - $line";
            if($line =~ m#$regex{$apt->{lang}}{update}#i) {
                $update->{'state'}  = 'done';
                Log3 'Update', 4, "Daten erhalten";

            } elsif($line =~ s#^E: ##) { # error
                my $error = {};
                $error->{message} = $line;
                push(@{$update->{error}}, $error);
                $update->{'state'}  = 'errors';
                Log3 'Update', 4, "Error";

            } elsif($line =~ s#^W: ##) { # warning
                my $warning = {};
                $warning->{message} = $line;
                push(@{$update->{warning}}, $warning);
                $update->{'state'}  = 'warnings';
                Log3 'Update', 4, "Warning";
            }
        }
        
        close(APT);
    } else {
        die Log3 'Update', 2, "Couldn't use APT: $!";
        #die "Couldn't use APT: $!\n";
        $update->{error}    = 'Couldn\'t use APT: '.$;
    }

    return $update;
}

sub AptToDate_AptUpgradeList($) {

    my $apt     = shift;

    
    my $updates = {};

    if(open(APT, "echo n | $apt->{aptget} -s -q -V upgrade 2>&1 |")) {
        while(my $line = <APT>) {
            chomp($line);
            Log3 'AptToDate', 4, "Sub AptToDate_AptUpgradeList - $line";

            if($line =~ m#^\s+(\S+)\s+\((\S+)\s+=>\s+(\S+)\)#) {
                my $update = {};
                my $package = $1;
                $update->{current} = $2;
                $update->{new} = $3;
                $updates->{packages}->{$package} = $update;

            } elsif($line =~ s#^W: ##) { # warning
                my $warning = {};
                $warning->{message} = $line;
                push(@{$updates->{warning}}, $warning);
            
            } elsif($line =~ s#^E: ##) { # error
                my $error = {};
                $error->{message} = $line;
                push(@{$updates->{error}}, $error);
            }
        }
        
        close(APT);
    } else {
        die Log3 'Update', 2, "Couldn't use APT: $!";
        #die "Couldn't use APT: $!\n";
        $updates->{error}    = 'Couldn\'t use APT: '.$;
    }

    return $updates;
}

sub AptToDate_AptToUpgrade($) {

    my $apt     = shift;

    
    my $updates = {};

    if(open(APT, "echo n | $apt->{aptget} -y -q -V upgrade 2>&1 |")) {
        while(my $line = <APT>) {
            chomp($line);
            Log3 'AptToDate', 4, "Sub AptToDate_AptToUpgrade - $line";
            
            if($line =~ m#$regex{$apt->{lang}}{upgrade}#) {
                my $update = {};
                my $package = $1;
                $update->{new} = $2;
                $update->{current} = $3;
                $updates->{packages}->{$package} = $update;
      
            } elsif($line =~ s#^W: ##) { # warning
                my $warning = {};
                $warning->{message} = $line;
                push(@{$updates->{warning}}, $warning);
            
            } elsif($line =~ s#^E: ##) { # error
                my $error = {};
                $error->{message} = $line;
                push(@{$updates->{error}}, $error);
            }
        }
        
        close(APT);
    } else {
        die Log3 'Update', 2, "Couldn't use APT: $!";
        #die "Couldn't use APT: $!\n";
        $updates->{error}    = 'Couldn\'t use APT: '.$;
    }

    return $updates;
}

####################################################
# End Childprozess
####################################################

sub AptToDate_PreProcessing($$) {

    my ($hash,$json)    = @_;
    
    
    my $name            = $hash->{NAME};
    
    my $decode_json     = eval{decode_json($json)};
    if($@){
        Log3 $name, 2, "AptToDate ($name) - JSON error: $@";
        return;
    }
    
    Log3 $hash, 4, "AptToDate ($name) - JSON: $json";

    $hash->{".fhem"}{aptget}{packages}          = $decode_json->{packages} if( $hash->{".fhem"}{aptget}{cmd} eq 'getUpdateList' );
    $hash->{".fhem"}{aptget}{updatedpackages}   = $decode_json->{packages} if( $hash->{".fhem"}{aptget}{cmd} eq 'toUpgrade' );
    
    if( defined($decode_json->{warning}) or defined($decode_json->{error}) ) {
        $hash->{".fhem"}{aptget}{'warnings'}        = $decode_json->{warning} if( defined($decode_json->{warning}) );
        $hash->{".fhem"}{aptget}{errors}            = $decode_json->{error} if( defined($decode_json->{error}) );
    } else {
        delete $hash->{".fhem"}{aptget}{'warnings'};
        delete $hash->{".fhem"}{aptget}{errors};
    }
    
    AptToDate_WriteReadings($hash,$decode_json);
}

sub AptToDate_WriteReadings($$) {

    my ($hash,$decode_json)    = @_;
    
    my $name            = $hash->{NAME};
    
    Log3 $hash, 4, "AptToDate ($name) - Write Readings";
    Log3 $hash, 5, "AptToDate ($name) - ".Dumper $decode_json;
    Log3 $hash, 5, "AptToDate ($name) - Packges Anzahl: ".scalar keys %{$decode_json->{packages}};
    Log3 $hash, 5, "AptToDate ($name) - Inhalt aptget cmd: ".scalar keys %{$decode_json->{packages}};

    
    readingsBeginUpdate($hash);
    
    if( $hash->{".fhem"}{aptget}{cmd} eq 'repoSync' ) {
        readingsBulkUpdate($hash,'repoSync','fetched '.$decode_json->{'state'}) ;
        $hash->{helper}{lastSync}   = AptToDate_ToDay();
    }
    
    readingsBulkUpdateIfChanged($hash,'updatesAvailable',scalar keys %{$decode_json->{packages}}) if( $hash->{".fhem"}{aptget}{cmd} eq 'getUpdateList' );
    readingsBulkUpdate($hash,'toUpgrade','successful') if( $hash->{".fhem"}{aptget}{cmd} eq 'toUpgrade' and not defined($hash->{".fhem"}{aptget}{'errors'}) and not defined($hash->{".fhem"}{aptget}{'warnings'}) );
    
    if( $hash->{".fhem"}{aptget}{cmd} eq 'getDistribution' ) {
        while( my ($r,$v) = each %{$decode_json->{'os-release'}} ) {
            readingsBulkUpdateIfChanged($hash,$r,$v);
        }
    }
    
    if( defined($decode_json->{error}) ) {
        readingsBulkUpdate($hash,'state',$hash->{".fhem"}{aptget}{cmd}.' Errors (get showErrorList)');
    } elsif( defined($decode_json->{warning}) ) {
        readingsBulkUpdate($hash,'state',$hash->{".fhem"}{aptget}{cmd}.' Warnings (get showWarningList)');
    } else {
        readingsBulkUpdate($hash,'state',(scalar keys %{$decode_json->{packages}} > 0 ? 'system updates available' : 'system is up to date') );
        
    }
    
    readingsEndUpdate($hash,1);
    
    AptToDate_ProcessUpdateTimer($hash) if( $hash->{".fhem"}{aptget}{cmd} eq 'getDistribution' );
}

sub AptToDate_CreateUpgradeList($$) {

    my ($hash,$getCmd)  = @_;
    
    
    my $packages;
    $packages           = $hash->{".fhem"}{aptget}{packages} if($getCmd eq 'showUpgradeList');
    $packages           = $hash->{".fhem"}{aptget}{updatedpackages} if($getCmd eq 'showUpdatedList');
        
    my $ret = '<html><table><tr><td>';
    $ret .= '<table class="block wide">';
    $ret .= '<tr class="even">';
    $ret .= "<td><b>Packagename</b></td>";
    $ret .= "<td><b>Current Version</b></td>" if($getCmd eq 'showUpgradeList');
    $ret .= "<td><b>Over Version</b></td>" if($getCmd eq 'showUpdatedList');
    $ret .= "<td><b>New Version</b></td>";;
    $ret .= "<td></td>";
    $ret .= '</tr>';
    
    if( ref($packages) eq "HASH" ) {

        my $linecount = 1;
        foreach my $package (keys (%{$packages}) ) {
            if ( $linecount % 2 == 0 ) {
                $ret .= '<tr class="even">';
            } else {
                $ret .= '<tr class="odd">';
            }

            $ret .= "<td>$package</td>";
            $ret .= "<td>$packages->{$package}{current}</td>";
            $ret .= "<td>$packages->{$package}{new}</td>";
            
            $ret .= '</tr>';
            $linecount++;
        }
    }
    
    $ret .= '</table></td></tr>';
    $ret .= '</table></html>';

    return $ret;
}

sub AptToDate_CreateWarningList($) {

    my $hash        = shift;


    my $warnings    = $hash->{".fhem"}{aptget}{'warnings'};
        
    my $ret = '<html><table><tr><td>';
    $ret .= '<table class="block wide">';
    $ret .= '<tr class="even">';
    $ret .= "<td><b>Warning List</b></td>";
    $ret .= "<td></td>";
    $ret .= '</tr>';
    
    if( ref($warnings) eq "ARRAY" ) {

        my $linecount = 1;
        foreach my $warning (@{$warnings}) {
            if ( $linecount % 2 == 0 ) {
                $ret .= '<tr class="even">';
            } else {
                $ret .= '<tr class="odd">';
            }

            $ret .= "<td>$warning->{message}</td>";

            $ret .= '</tr>';
            $linecount++;
        }
    }
    
    $ret .= '</table></td></tr>';
    $ret .= '</table></html>';

    return $ret;
}

sub AptToDate_CreateErrorList($) {

    my $hash    = shift;


    my $errors  = $hash->{".fhem"}{aptget}{'errors'};
        
    my $ret = '<html><table><tr><td>';
    $ret .= '<table class="block wide">';
    $ret .= '<tr class="even">';
    $ret .= "<td><b>Warning List</b></td>";
    $ret .= "<td></td>";
    $ret .= '</tr>';
    
    if( ref($errors) eq "ARRAY" ) {

        my $linecount = 1;
        foreach my $error (@{$errors}) {
            if ( $linecount % 2 == 0 ) {
                $ret .= '<tr class="even">';
            } else {
                $ret .= '<tr class="odd">';
            }

            $ret .= "<td>$error->{message}</td>";

            $ret .= '</tr>';
            $linecount++;
        }
    }
    
    $ret .= '</table></td></tr>';
    $ret .= '</table></html>';

    return $ret;
}

#### my little helper
sub AptToDate_ToDay() {

    my ($sec,$min,$hour,$mday,$month,$year,$wday,$yday,$isdst)  = localtime(gettimeofday());
    
    $month++;
    $year+=1900;
    
    my $today = sprintf('%04d-%02d-%02d', $year,$month,$mday);
    
    return $today;
}






1;








=pod
=item device
=item summary       
=item summary_DE    

=begin html

<a name="AptToDate"></a>
<h3>Apt Update Information</h3>
<ul>

</ul>

=end html

=begin html_DE

<a name="AptToDate"></a>
<h3>Apt Update Information</h3>
<ul>

</ul>

=end html_DE

=cut
