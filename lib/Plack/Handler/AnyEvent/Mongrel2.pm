package Plack::Handler::AnyEvent::Mongrel2;
# ABSTRACT: run a PSGI app with AnyEvent::Mongrel2
use strict;
use warnings;
use true;
use namespace::autoclean -also => [qw/_fix/];

use AnyEvent::Mongrel2;
use AnyEvent::Mongrel2::PSGI;
use ZeroMQ::Raw::Context;

use Carp::Always;

my $have_coro = eval "require Coro; 1";

sub _fix {
    my $str = shift;
    $str =~ s/-/_/g;
    return $str;
}

sub new {
    my ($class, %args) = @_;
    %args = map { _fix($_) => $args{$_} } keys %args;
    return bless { %args }, $class;
}

sub _build_m2 {
    my $self = shift;
    $self->{context} ||= ZeroMQ::Raw::Context->new( threads => 1 );
    return AnyEvent::Mongrel2->new(
        %$self,
    );
}

sub _start_app {
    my ($self, $app) = @_;
    my $use_coro = $have_coro && $self->{'coro'};
    return AnyEvent::Mongrel2::PSGI->new(
        mongrel2 => $self->_build_m2,
        coro     => $use_coro,
        app      => $app,
    );
}

sub register_service {
    my ($self, $app) = @_;
    $self->_start_app($app);
}


sub run {
    my ($self, $app) = @_;
    $self->register_service($app);
    AnyEvent->condvar->recv;
}

__END__

=head1 SYNOPSIS

Mongrel2 needs a bit more configuration than most servers, so the
command-line is kind of long:

    plackup app.psgi -s AnyEvent::Mongrel2       \
        --request-endpoint tcp://127.0.0.1:1234  \
        --response-endpoint tcp://127.0.0.1:1235 \
        --request-identity 5fb4feb1-d690-46f9-ba50-4a11f96fe720 \
        --coro 1

The command-line args you can pass are the INITARGS that you'd pass
when instantiating L<AnyEvent::Mongrel2>.

Set Coro to 1 if you want C<psgi.multithread>.  This will cause each
request to occur in its own coroutine, which can block without
blocking the other coroutines.
