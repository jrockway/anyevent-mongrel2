package AnyEvent::Mongrel2::Handle;
# ABSTRACT: Handle-ish API for Mongrel2 connections
use Moose;
use MooseX::Aliases;
use true;
use namespace::autoclean;

with 'MooseX::Role::EventQueue' => {
    name   => 'read',
    method => '_inject_message',
};

has 'mongrel2' => (
    is       => 'ro',
    isa      => 'AnyEvent::Mongrel2',
    required => 1,
    weak_ref => 1,
    handles  => [qw/send_response defer_response/],
);

has 'uuid' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has 'id' => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has 'path' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has 'is_connected' => (
    is      => 'rw',
    isa     => 'Bool',
    default => 1,
);

has 'is_shutdown' => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

sub _read_state_change {}

sub assert_connected {
    my $self = shift;
    confess 'handle is not connected anymore' unless $self->is_connected;
}

before [qw/close write/] => sub { $_[0]->assert_connected };

sub write {
    my ($self, $data) = @_;
    if(ref $data){
        $self->defer_resposne( $data, $self->uuid, $self->id );
    }
    else {
        $self->send_response( $data, $self->uuid, $self->id );
    }
}

sub close {
    my ($self) = @_;
    $self->write('');
    $self->is_connected(0);
}

sub poll_cb {
    my ($self, $cb) = @_;

    my $call_forever; $call_forever = sub {
        my $handle = shift;
        if($self->is_connected && !$self->is_shutdown){
            my $data = $cb->();
            if($self->is_connected && !$self->is_shutdown){
                $handle->write($call_forever);
            }
            return $data;
        }
        return;
    };

    $self->push_write($call_forever);
    return;
}

sub DEMOLISH {
    my $self = shift;
    # warn sprintf("handle %d is going away\n", $self->id);
    $self->close if $self->is_connected;
}

__PACKAGE__->meta->make_immutable;
