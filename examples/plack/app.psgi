use Carp::Always;
my $app = sub {
    my $env = shift;
    return [ 200, ['Content-Type' => 'text/plain'], ['Hello, world!'] ];
};
