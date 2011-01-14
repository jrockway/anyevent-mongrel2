use strict;
use warnings;
use Test::More tests => 15;
use Plack::Loader;
use Coro;
use EV;
use Coro::EV;
use LWP::UserAgent;
use Coro::LWP;
use JSON::XS;
use Coro::Handle;
use AnyEvent::Socket;
use MIME::Base64 qw(decode_base64);

use t::lib::m2 qw(m2);

my %server = m2;

my $port = delete $server{port};

my $json_count = 0;
my $xml_count  = 0;

async {
    eval {
        my $server = Plack::Loader->load( 'AnyEvent::Mongrel2' => (
            port => $port,
            coro => 1,
            %server,
        ));

        my @scope_hack;

        $server->run(sub {
            my $env = shift;
            if($env->{PATH_INFO} =~ /^(?:\@data|<data)/){
                my $handle = $env->{'psgix.io'};
                push @scope_hack, $handle;

                if($handle->type eq 'JSON'){
                    $json_count++;
                    return sub {
                        $handle->push_read(sub {
                            my ($h, $r) = @_;
                            $r->{reqnum} = 1;
                            $h->write(encode_json($r));
                        });
                        $handle->push_read(sub {
                            my ($h, $r) = @_;
                            $r->{reqnum} = 2;
                            $h->write(encode_json($r));
                            $h->close;
                            @scope_hack = ();
                        });
                    };
                }
                elsif($handle->type eq 'XML'){
                    $xml_count++;
                    return sub {
                        $handle->push_read(sub {
                            my ($h, $r) = @_;
                            $h->write('<response>1</response>');
                        });
                        $handle->push_read(sub {
                            my ($h, $r) = @_;
                            $h->write('<response>2</response>');
                            $h->close;
                            @scope_hack = ();
                        });
                    }
                }
            }
            elsif($env->{REQUEST_URI} =~ /OHHAI/){
                return sub {
                    my $w = [ 200, ['Content-Length' => 13] ];
                    Coro::EV::timer_once 1;
                    $env->{'psgix.io'}->write("Hello, world!");
                    $env->{'psgix.io'}->close;
                }
            }
            else {
                return [ 404, [], ['not found'] ];
            }
        });
    };
};

async { EV::loop };

my $ua = LWP::UserAgent->new;

my @stuff;
push @stuff, async {
    my $res = $ua->get("http://localhost:$port/test");
    is $res->code, 404, 'not found ok';
};

push @stuff, async {
    my $res = $ua->get("http://localhost:$port/OHHAI");
    is $res->code, 200, '200 ok';
    like $res->decoded_content, qr/Hello, world!/, 'got hello world';
};


push @stuff, async {
    tcp_connect '127.0.0.1', $port, Coro::rouse_cb;
    my $fh = unblock +(Coro::rouse_wait)[0];
    my $hash = { foo => 'bar', bar => 'baz' };
    $fh->print(join '', '@data ', encode_json($hash), "\0");
    my $res = $fh->readline("\0");
    chop $res;
    ok $res, "got json $res";
    $hash->{reqnum} = 1;
    is_deeply decode_json(decode_base64($res)), $hash, 'got hash echoed back';

    delete $hash->{reqnum};
    $hash->{bar} = 'BAZ';
    $fh->print(join '', '@data ', encode_json($hash), "\0");
    $res = $fh->readline("\0");
    chop $res;
    ok $res, "got another json response $res";
    $hash->{reqnum} = 2;
    is_deeply decode_json(decode_base64($res)), $hash, 'got hash echoed back';
    $fh->shutdown;
    $fh->close;

    is $json_count, 1, 'only called handler once';
};

push @stuff, async {
    tcp_connect '127.0.0.1', $port, Coro::rouse_cb;
    my $fh = unblock +(Coro::rouse_wait)[0];

    $fh->print("<data>oh hai</data>\0");
    my $res = $fh->readline("\0");
    chop $res;
    ok $res, "got some XML";
    is decode_base64($res), '<response>1</response>', 'got response 1';

    $fh->print("<data>oh hai again</data>\0");
    $res = $fh->readline("\0");
    chop $res;
    ok $res, "got some XML";
    is decode_base64($res), '<response>2</response>', 'got response 2';

    is $xml_count, 1, 'called xml handler once';
};

map { $_->join } @stuff;

EV::break();
