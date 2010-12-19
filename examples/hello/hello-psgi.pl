#!/usr/bin/env perl

use strict;
use warnings;
use feature ':5.10';

use FindBin qw($Bin);
use lib "$Bin/../../lib";

use EV;
use AnyEvent;
use AnyEvent::Mongrel2;
use AnyEvent::Mongrel2::PSGI;
use ZeroMQ::Raw::Context;

my $c = ZeroMQ::Raw::Context->new( threads => 1 );

my $m2 = AnyEvent::Mongrel2->new(
    context           => $c,
    request_identity  => 'hello',
    request_endpoint  => 'tcp://127.0.0.1:1234',
    response_endpoint => 'tcp://127.0.0.1:1235',
);

my $psgi = AnyEvent::Mongrel2::PSGI->new(
    mongrel2 => $m2,
    app      => sub {
        my $env = shift;
        given($env->{QUERY_STRING}){
            when(/handle/){
                open my $fh, '<', '/etc/passwd' or die "OH NOES";
                return [
                    200,
                    [ 'Content-Type' => 'text/plain' ],
                    $fh,
                ];
            }
            when(/die/){
                die 'a perl error';
            }
            when(/defer/){
                return sub {
                    my $respond = shift;
                    my $t; $t = AnyEvent->timer( after => 1, cb => sub {
                        undef $t;
                        $respond->([
                            200,
                            [ 'Content-Type' => 'text/plain' ],
                            [ 'Hello, deferred world!' ],
                        ]);
                    });
                    return;
                }
            }
            when(/stream/){
                return sub {
                    my $respond = shift;
                    my $i = 4;
                    my $t; $t = AnyEvent->timer( after => 1, cb => sub {
                        undef $t;
                        my $writer = $respond->([
                            200,
                            [ 'Content-Type' => 'text/plain' ],
                        ]);

                        $t = AnyEvent->timer( after => 1, interval => 1, cb => sub {
                            if(--$i < 0){
                                undef $t;
                                $writer->close;
                            }
                            $writer->write("$i\n");
                        });
                    });
                };
            }
            default {
                return [
                    200,
                    [ 'Content-Type' => 'text/plain' ],
                    [ 'Hello, ', 'world!' ],
                ];
            }
        }
    },
);

say 'listening for requests on tcp://127.0.0.1:1234';

EV::run();
