package AnyEvent::Mongrel2::Trait::WithHandles;
# ABSTRACT: build an AnyEvent::Mongrel2::Handle for each connection
use Moose::Role;
use true;
use namespace::autoclean;
use JSON;
use Scalar::Util qw(weaken);
use AnyEvent::Mongrel2::Handle;

has 'handles' => (
    reader  => 'handles',
    isa     => 'HashRef',
    default => sub { +{} },
    traits  => ['Hash'],
    handles => { '_get_handle_for' => 'get' },
);

sub _register_handle {
    my ($self, $handle) = @_;
    my $id = $handle->id // confess "handle $handle does not have an id!";
    $self->handles->{$id} = $handle;
    weaken $self->handles->{$id};
    return;
}

around 'parse_request' => sub {
    my ($orig, $self, @args) = @_;
    my $hash = $self->$orig(@args);

    my $first_time = 0;
    my $handle = $self->_get_handle_for($hash->{id});

    my $type =
        $hash->{headers}{METHOD} eq 'JSON' ? 'JSON' :
        $hash->{headers}{METHOD} eq 'XML'  ? 'XML'  : 'HTTP';

    if(!$handle){
        $handle = AnyEvent::Mongrel2::Handle->new(
            mongrel2 => $self,
            uuid     => $hash->{uuid},
            id       => $hash->{id},
            path     => $hash->{path},
            type     => $type,
        );
        $self->_register_handle($handle);
        $first_time = 1;
    }

    my $inject;

    if($type eq 'JSON'){
        $hash->{json_body} = decode_json($hash->{body});

        no warnings 'uninitialized';
        if( $hash->{json_body}{type} eq 'disconnect' ){
            $handle->is_connected(0);
            $handle->is_shutdown(1);
            delete $self->handles->{$hash->{id}};
            $hash->{stop} = 1;

        }
        else {
            $inject = $hash->{json_body};
        }
    }
    elsif($type eq 'XML'){
        # i really don't want to page in XML::LibXML2 just for a
        # feature nobody will ever use, so parse this yourself.
        $inject = { xml => $hash->{body} };
    }

    if(defined $inject){
        $handle->_inject_message($inject);
        $hash->{stop} = 1 unless $first_time;
    }

    $hash->{handle} = $handle;

    return $hash;
};
