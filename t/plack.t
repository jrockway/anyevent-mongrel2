use strict;
use warnings;
use Test::More;
use Plack::Test::Suite;

use t::lib::m2 qw(m2);

my %server = m2;

diag "waiting a bit for mongrel2 to start up";
sleep 1;

Plack::Test::Suite->run_server_tests(
    'AnyEvent::Mongrel2', $server{port}, $server{port},
    request_identity  => $server{request_identity},
    request_endpoint  => $server{request_endpoint},
    response_endpoint => $server{response_endpoint},
);

done_testing;
