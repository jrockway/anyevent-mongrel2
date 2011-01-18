use strict;
use warnings;
use Test::More;
use Plack::Test::Suite;
use Plack::Handler::AnyEvent::Mongrel2::Standalone;
use Plack::Middleware::Lint;

my $m2 = Plack::Handler::AnyEvent::Mongrel2::Standalone->new;
ok $m2->pid;

# a short nap seems to be helpful
sleep 2;

Plack::Test::Suite->run_server_tests(sub {
    my($port, $app) = @_;
    $app = Plack::Middleware::Lint->wrap($app);
    $m2->run($app);
}, 5000, 5000);

done_testing;

kill 9, $m2->pid;
