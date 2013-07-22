#!/usr/bin/perl -I/home/hugh

use strict;
use warnings;
use autodie;

my $num_to_get = 5;
my $force = 0;

my %urls = (
    'resolver1.opendns.com' => 'dns',
    'resolver2.opendns.com' => 'dns',
    'resolver3.opendns.com' => 'dns',
    'resolver4.opendns.com' => 'dns',
#    'automation.whatismyip.com/n09230945.asp' => 'http',
    'ip.alt.io' => 'http',
    'cfaj.freeshell.org/ipaddr.cgi' => 'http',
    'ip.appspot.com' => 'http',
#    'slurpware.org' => 'http',
#    'myip.dnsomatic.com' => 'http',
    'ifconfig.me/ip' => 'http',
    'ipecho.net/plain' => 'http',
    'ipv4.icanhazip.com' => 'http',
#    'tnx.nl/ip' => 'http',
    'curlmyip.com' => 'http',
    'myip.dnsdynamic.org' => 'http',
);

my @domains = (
    'torus.co.nz',
    'davenport.net.nz',
    'bennett.net.nz',
    'allthethings.co.nz',
);

sub findip {
    use List::Util qw(shuffle);
# TODO: parse ip for validity...
    my $ip = undef;

    if ($#ARGV == 0) {
        $ip = $ARGV[0];
        return $ip;
    }

    my $num_got = 0;

    foreach my $url (shuffle(keys(%urls))) {
        my $type = $urls{$url};
        my $funname = 'findip_' . $type;
        my $fun = \&$funname;
        my $result = &$fun($url);
        if ($result) {
            chomp $result;
            if ($ip && $ip ne $result) {
                warn "Got conflicting ip's\n";
                warn $ip . " " . $result . " " . $url;
                $ip = undef;
                last;
            }
            $ip = $result unless $ip;
            $num_got ++;
            if ($num_got == $num_to_get) {
                last;
            }
        } else {
            warn "url $url failed to obtain ip\n";
        }
    }

    if ($num_got != $num_to_get) {
        warn "Not enough results - got $num_got - needed $num_to_get\n";
        warn $ip;
        $ip = undef;
    }

    return $ip;
}

sub findip_dns {
    use Net::DNS;

    my $nameserver = shift;

    my $res = Net::DNS::Resolver->new(
        nameservers => [$nameserver],
        retrans => 0,
        retry => 1,
    );

    my $query = $res->query('myip.opendns.com');

    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq 'A';
            return $rr->address;
        }
        warn "No A record found";
    } else {
        warn $res->errorstring;
    }
    return undef;
}

sub findip_http {
    use HTTP::Request;
    use LWP::UserAgent;

    my $url = shift;
    if ($url !~ '^http:\/\/') {
        $url = 'http://' . $url;
    }

    my $ua = LWP::UserAgent->new();
    $ua->agent('curl/7.21.0 (x86_64-pc-linux-gnu) libcurl/7.21.0 OpenSSL/0.9.8o zlib/1.2.3.4 libidn/1.15 libssh2/1.2.6');

    my $request = HTTP::Request->new(
        GET => $url,
    );

    my $result = $ua->request($request);

    if ($result->is_success) {
        return $result->content;
    } else {
        warn $result->status_line;
    }
    return undef;
};

sub update_zonefile {
    use DNS::ZoneParse;

    my $domain = shift;
    my $ip = shift;

    my $zonefile = DNS::ZoneParse->new(
        '/etc/nsd3/templates.d/' . $domain,
    );

    $zonefile->new_serial();

    open FH, '>', '/etc/nsd3/templates.d/' . $domain;
    print FH $zonefile->output();
    close FH;

    my $a_records = $zonefile->a;
    foreach my $record (@$a_records) {
        $record->{'host'} = $ip if $record->{'host'} eq '127.0.0.1';
    }

    open FH, '>', '/etc/nsd3/zones.d/' . $domain;
    print FH $zonefile->output();
    close FH;

    return;
}

sub update_registrar {
    use HTTP::Request;
    use HTTP::Request::Common qw(POST);
    use LWP::UserAgent;
    use HTML::TreeBuilder;

    require '/etc/nsd3/credentials.inc';
    our ($login, $password);

    my $domain = shift;
    my $ip = shift;

    my ($ua, $request, $result, $tree);
    my @elements;
    my %params;

    $ua = LWP::UserAgent->new();
    $ua->agent('curl/7.21.0 (x86_64-pc-linux-gnu) libcurl/7.21.0 OpenSSL/0.9.8o zlib/1.2.3.4 libidn/1.15 libssh2/1.2.6');
    $ua->cookie_jar( {} );

    $request = POST 'https://www.1stdomains.net.nz/client/login.php',
        [
            action           => 'login',
            account_login    => $login,
            account_password => $password,
        ],
    ;

    $result = $ua->request($request);

    if ($result->is_error) {
        die $result->status_line;
    }

    $request = HTTP::Request->new(
        GET => 'https://www.1stdomains.net.nz/client/domain_manager.php?domain_name=' . $domain,
    );
    $result = $ua->request($request);

    if ($result->is_error) {
        die $result->status_line;
    }

    $request = HTTP::Request->new(
        GET => 'https://www.1stdomains.net.nz/client/nameserver_delegation.php',
    );
    $result = $ua->request($request);

    if ($result->is_error) {
        die $result->status_line;
    }

    $tree = HTML::TreeBuilder->new_from_content($result->content);
    @elements = $tree->find_by_tag_name('input');
    foreach my $input (@elements) {
        $params{$input->attr('name')} = $input->attr('value');
        if ($input->attr('name') =~ /nameserver_ip/
            && $input->attr('value')) {
            $params{$input->attr('name')} = $ip;
        }
    }
    $params{action} = 'update';

    $request = POST 'https://www.1stdomains.net.nz/client/nameserver_delegation.php',
        \%params,
    ;
    $result = $ua->request($request);

    if ($result->is_error) {
        die $result->status_line;
    }

    return;
}

my $oldip = undef;
{
    no autodie qw(open);
    if (open FH, '<', '/etc/nsd3/ipaddr') {
        $oldip = <FH>;
        close FH;
    }
    use autodie;
}

my $ip = findip();
die "no ip found\n" unless $ip;

print $ip;

if ($force || ! defined $oldip || $oldip ne $ip) {
    foreach my $domain (@domains) {
        update_zonefile($domain, $ip);
        print STDERR "updated zone file for $domain\n";
    }
    system('/usr/sbin/nsdc rebuild');
    system('/usr/sbin/nsdc reload');
    print STDERR "updated nsd\n";
    update_registrar('torus.co.nz', $ip);
    print STDERR "updated 1st domains";
} else {
    print STDERR "no change";
}

open FH, '>', '/etc/nsd3/ipaddr';
print FH $ip;
close FH;

exit 0;
