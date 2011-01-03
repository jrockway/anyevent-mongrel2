package AnyEvent::Mongrel2;
# ABSTRACT: talk to a Mongrel2 server
use Moose;
use true;
use namespace::autoclean;

use List::MoreUtils qw(natatime);

use AnyEvent::ZeroMQ::Publish;
use AnyEvent::ZeroMQ::Pull;

use AnyEvent::ZeroMQ::Types qw(Endpoint);

with 'MooseX::Traits';
has '+_trait_namespace' => ( default => __PACKAGE__.'::Trait' );

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
    is        => 'rw',
    isa       => 'CodeRef',
    predicate => 'has_handler',
    trigger   => sub {
        # basically, we can't handle connections until we have a
        # handler, so we don't create the sockets until a handler is
        # provided.  this lets you write a request handling-object
        # that has_a its mongrel2 server.
        my ($self, $new, $old) = @_;
        if(!$old){
            $self->request_source;
            $self->response_sink;
        }
    }
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

sub parse_request {
    my ($self, $msg) = @_;
    my ($uuid, $id, $path, $rest) = split /[[:space:]]/, $msg, 4;
    my @rest;
    # decode headers and body, which are both netstrings
    while($rest =~ /^(\d+):(.+)$/sg){
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

sub _compute_response {
    my ($self, $chunk, $uuid, @to) = @_;

    # note that we don't validate the length of @to; that's up to the
    # caller
    my $to = join ' ', @to;
    my $msg = sprintf("%s %d:%s, %s", $uuid, length $to, $to, $chunk);
    return $msg;
}

sub send_response {
    my ($self, $chunk, $uuid, @to) = @_;
    return unless @to > 0;

    if(@to > 128){
        # mongrel2 says it will send to 128 clients at a time, so
        # partition @to into 128 recipient chunks
        my $chunker = natatime 128, @to;
        while(my @chunk_to = $chunker->()){
            my $msg = $self->_compute_response($chunk, $uuid, @chunk_to);
            $self->push_write($msg);
        }
    }
    else {
        # profiling reveals that this micro-optimization is worthwhile.
        $self->push_write(
            $self->_compute_response($chunk, $uuid, @to),
        );
    }
}

sub defer_response {
    my ($self, $code, $uuid, @to) = @_;
    my $to = join ' ', @to;

    # this situation is best left to the user, as there is no good
    # default behavior.  my advice is to just precompute the result
    # unless it's a 200GB movie or something.  and in that case, maybe
    # convince the internet to support multicast properly instead of
    # streaming a 200GB movie to 129 client with perl.  JMHO.
    confess 'too many recipients for defer_response, max 128'
        if @to > 128;

    $self->push_write(sub {
        my $chunk = $code->();
        return
    });
}

sub call_handler {
    my ($self, $h, $msg) = @_;
    my $req = $self->parse_request($msg);
    return if exists $req->{stop} && $req->{stop};
    $self->handler->($self, $req) if $self->has_handler;
}

__PACKAGE__->meta->make_immutable;
