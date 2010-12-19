package AnyEvent::Mongrel2;
# ABSTRACT: talk to a Mongrel2 server
use Moose;
use true;
use namespace::autoclean;

use AnyEvent::ZeroMQ::Publish;
use AnyEvent::ZeroMQ::Pull;

use AnyEvent::ZeroMQ::Types qw(Endpoint);

has [qw/request_identity response_identity/] => (
    is      => 'ro',
    isa     => 'Str',
);

has [qw/request_endpoint response_endpoint/] => (
    is       => 'ro',
    isa      => Endpoint,
    required => 1,
);

has 'handler' => (
    is       => 'ro',
    isa      => 'CodeRef',
    required => 1,
);

has 'context' => (
    is       => 'ro',
    isa      => 'ZeroMQ::Raw::Context',
    required => 1,
);

has 'request_source' => (
    is         => 'ro',
    does       => 'AnyEvent::ZeroMQ::Handle::Role::Readable',
    handles    => 'AnyEvent::ZeroMQ::Handle::Role::Readable',
    lazy_build => 1,
);

has 'response_sink' => (
    is         => 'ro',
    does       => 'AnyEvent::ZeroMQ::Handle::Role::Writable',
    handles    => 'AnyEvent::ZeroMQ::Handle::Role::Writable',
    lazy_build => 1,
);

sub _build_request_source {
    my $self = shift;
    return AnyEvent::ZeroMQ::Pull->new(
        context  => $self->context,
        identity => $self->request_identity,
        connect  => $self->request_endpoint,
        on_read  => sub {
            my ($h, $msg) = @_;
            $self->call_handler($h, $msg);
        },
    );
}

sub _build_response_sink {
    my $self = shift;
    return AnyEvent::ZeroMQ::Publish->with_traits('Topics')->new(
        context  => $self->context,
        connect  => $self->response_endpoint,
        $self->response_identity ? (identity => $self->response_identity) : (),
    );
}

around 'push_write' => sub {
    my ($orig, $self, $msg) = @_;
    $self->$orig($msg, topic => $self->response_identity);
};

sub BUILD {
    my $self = shift;
    $self->request_source;
    $self->response_sink;
}

sub parse_request {
    my ($self, $msg) = @_;
    my ($uuid, $id, $path, $rest) = split /[[:space:]]/, $msg, 4;
    my @rest;
    # decode headers and body, which are both netstrings
    while($rest =~ /^(\d+):(.+)$/g){
        my ($data, $comma, $more) = unpack "A$1 A A*", $2;
        confess 'invalid netstring' unless $comma eq ',';
        $rest = $more;
        push @rest, $data;
    }

    return {
        uuid    => $uuid,
        id      => $id,
        path    => $path,
        headers => $rest[0],
        body    => $rest[1],
    }
}

sub send_response {
    my ($self, $chunk, $uuid, @to) = @_;
    my $to = join ' ', @to;
    my $msg = sprintf("%s %d:%s, %s", $uuid, length $to, $to, $chunk);
    $self->push_write($msg);
}

sub call_handler {
    my ($self, $h, $msg) = @_;
    my $req = $self->parse_request($msg);
    $self->handler->($self, $req);
}

__PACKAGE__->meta->make_immutable;
