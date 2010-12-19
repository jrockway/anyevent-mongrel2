#!/usr/bin/env perl

use strict;
use warnings;
use feature ':5.10';

use FindBin qw($Bin);
use lib "$Bin/../../lib";

use EV;
use AnyEvent::Mongrel2;
use ZeroMQ::Raw::Context;

my $c = ZeroMQ::Raw::Context->new( threads => 1 );

my $m2 = AnyEvent::Mongrel2->new(
    context           => $c,
    request_identity  => 'hello',
    request_endpoint  => 'tcp://127.0.0.1:1234',
    response_endpoint => 'tcp://127.0.0.1:1235',
    handler           => sub {
        my ($m2, $send, $req) = @_;

        # you can call send as many times as you like
        my $first = "HTTP/1.1 200 OK\r\n";
        $send->($first, $req->{uuid}, $req->{id});
        my $more  = "Content-Length: 13\r\n";
        $send->($more, $req->{uuid}, $req->{id});
        $more = "\r\n";
        $send->($more, $req->{uuid}, $req->{id});
        $send->("Hello, world!", $req->{uuid}, $req->{id});
    },
);

say 'listening for requests on tcp://127.0.0.1:1234';

EV::run();
