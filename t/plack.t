use strict;
use warnings;
use Test::More;
use Plack::Test::Suite;


Plack::Test::Suite->run_server_tests(
    'AnyEvent::Mongrel2', 8080, 8080,
    request_identity  => 'hello',
    request_endpoint  => 'tcp://127.0.0.1:1234',
    response_endpoint => 'tcp://127.0.0.1:1235',
);

done_testing;
