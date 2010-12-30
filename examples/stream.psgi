use strict;

# run with
# --request_endpoint tcp://127.0.0.1:1234 --response_endpoint tcp://127.0.0.1:1235 --request_identity hello

my %timers;

my @all_handles;

use AnyEvent;
$timers{internal} = AnyEvent->timer( after => 1, interval => 5, cb => sub {
    my $msg = "timers: " . (join ', ', keys %timers). "\r\n";

    @all_handles = grep { $_->is_connected } @all_handles;
    my @ids = map { $_->id } @all_handles;

    $all_handles[0]->send_response($msg, $all_handles[0]->uuid, @ids)
        if $all_handles[0];

    print $msg;
});

my $app = sub {
    my $env = shift;

    my $handle = $env->{'psgix.io'};
    my $id = $env->{'mongrel2.id'};

    push @all_handles, $handle;

    $timers{$id} = AnyEvent->timer( after => 0, interval => 1, cb => sub {
        if($handle->is_connected){
            $handle->write("hello, $id\r\n");
        }
        else {
            delete $timers{$id};
        }
    });

    return sub {
        # if you don't want this to be an HTTP response, just don't
        # call the callback :)
        my $send_headers = shift;
        $send_headers->([200, []]);
    };
};
