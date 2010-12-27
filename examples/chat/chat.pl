#!/usr/bin/env perl

use strict;
use warnings;
use feature ':5.10';

use FindBin qw($Bin);
use lib "$Bin/../../lib";

use EV;
use AnyEvent::Mongrel2;
use ZeroMQ::Raw::Context;
use JSON::XS;

my $c = ZeroMQ::Raw::Context->new( threads => 1 );

my %state;
my %nicks;

my $m2 = AnyEvent::Mongrel2->new(
    context           => $c,
    request_identity  => 'hello',
    request_endpoint  => 'tcp://127.0.0.1:1234',
    response_endpoint => 'tcp://127.0.0.1:1235',
    handler           => sub {
        my ($m2, $req) = @_;

        my $headers = decode_json($req->{headers});

        if($headers->{METHOD} ne 'JSON'){
            $m2->send_response(
                "HTTP/1.1 500 Bad Request\r\n".
                "Content-Length: 0\r\n".
                "Connection: close\r\n\r\n",
                $req->{uuid}, $req->{id},
            );
            return;
        }

        my $id = $req->{id};
        my $body = decode_json($req->{body});
        $state{$id} ||= 'seen';

        if($state{$id} eq 'seen' && $body->{type} eq 'join'){
            say "CONNECTED $id as ". $body->{user};

            # update state
            $nicks{$id} = $body->{user};
            $state{$id} = 'connected';

            # announce join to everyone
            $m2->send_response( $req->{body}, $req->{uuid}, keys %nicks )
                if %nicks;

            # send this guy the user list
            $m2->send_response( encode_json( {
                type  => 'userList',
                users => [ values %nicks ],
            }), $req->{uuid}, $id );
        }

        elsif( $body->{type} eq 'disconnect' ) {
            say "DISCONNECTED $id";
            delete $state{$id};
            delete $nicks{$id};

            # announce part to everyone
            $m2->send_response( $req->{body}, $req->{uuid}, keys %nicks )
                if %nicks;
        }

        elsif( $state{$id} eq 'connected' && $body->{type} eq 'msg' ){
            # announce msg to everyone
            $m2->send_response( $req->{body}, $req->{uuid}, keys %nicks )
                if %nicks;
        }

        use DDS;
        print Dump({ state => \%state, nicks => \%nicks });
    },
);

say 'listening for requests on tcp://127.0.0.1:1234';

EV::run();
