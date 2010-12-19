package AnyEvent::Mongrel2::PSGI::Writer;
# ABSTRACT: the writer object an app gets to stream the body
use strict;
use warnings;
use true;
use namespace::autoclean;

sub new {
    my ($class, $write, $poll_cb, $close) = @_;
    return bless [$write, $poll_cb, $close], $class;
}

sub write   { my $self = shift; $self->[0]->(@_) }
sub poll_cb { my $self = shift; $self->[1]->(@_) }
sub close   { my $self = shift; $self->[2]->(@_) }
