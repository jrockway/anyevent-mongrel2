package Plack::Handler::AnyEvent::Mongrel2::Standalone;
# ABSTRACT: create a standalone mongrel2 instance connected to a PSGI app
use Moose;
use true;
use namespace::autoclean;
use MooseX::Types::Structured qw(Dict);
use MooseX::Types::Moose qw(Str);
use MooseX::Types::UUID qw(UUID);

use AnyEvent::Mongrel2;
use AnyEvent::Mongrel2::PSGI;
use Mongrel2::Config;

use Data::UUID::LibUUID;
use File::Temp qw(tempdir);
use Path::Class;
use File::Which;

use autodie qw(mkdir chdir);

# BLAH
sub BUILDARGS {
    my ($class, %args) = @_;
    for my $key (keys %args){
        delete $args{$key} if !defined $args{$key};
    }
    if($args{listen} && ref $args{listen}){
        my $l = $args{listen}[0];
        confess 'listening on a unix socket is not supported'
            unless $l =~ /:/;
        my ($h,$p) = split /:/, $l;
        $h = '0.0.0.0' if !$h;
        $args{listen} = $h;
        $args{port}   = $p;
    }
    return \%args;
}

has 'host' => (
    is      => 'ro',
    isa     => 'Str',
    default => '127.0.0.1',
);

has 'listen' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { $_[0]->host },
);

has 'port' => (
    is      => 'ro',
    isa     => 'Int',
    default => '5000',
);

has 'mongrel2_path' => (
    is      => 'ro',
    isa     => 'Str',
    default => sub { which 'mongrel2' },
);

has 'config' => (
    is         => 'ro',
    lazy_build => 1,
    isa        => 'HashRef',
);

has 'database' => (
    is         => 'ro',
    isa        => 'Mongrel2::Config',
    lazy_build => 1,
);

has 'pid' => (
    reader     => 'pid',
    isa        => 'Int',
    lazy_build => 1,
);

sub _build_config {
    my $self = shift;

    my $server_uuid  = new_uuid_string();
    my $handler_uuid = new_uuid_string();

    my $tmpdir = dir(tempdir( CLEANUP => 1 ))->absolute->resolve;
    mkdir $tmpdir->subdir('sockets');
    mkdir $tmpdir->subdir('logs');

    return +{
        root         => $tmpdir->stringify,
        database     => $tmpdir->file('config.sqlite')->stringify,
        access_log   => dir('logs')->file('access.log')->stringify,
        error_log    => dir('logs')->file('error.log')->stringify,
        server_uuid  => $server_uuid,
        handler_uuid => $handler_uuid,
        send         => 'ipc://'.$tmpdir->subdir('sockets')->file('send'),
        recv         => 'ipc://'.$tmpdir->subdir('sockets')->file('recv'),
    };
}

sub _build_database {
    my $self = shift;
    my $config = $self->config;

    chdir $config->{root};
    my $s = Mongrel2::Config->connect('DBI:SQLite:config.sqlite');
    $s->txn_do(sub {
        $s->deploy;

        my $server = $s->resultset('Server')->create({
            uuid         => $config->{server_uuid},
            access_log   => $config->{access_log},
            error_log    => $config->{error_log},
            chroot       => $config->{root},
            pid_file     => $config->{root}.'/mongrel2.pid',
            default_host => $self->host,
            bind_addr    => $self->listen,
            port         => $self->port,
        });

        my $handler = $s->resultset('Handler')->create({
            send_spec  => $config->{send},
            recv_spec  => $config->{recv},
            send_ident => $config->{handler_uuid},
            recv_ident => $config->{server_uuid},
        });

        my @hosts;
        if($self->host eq 'localhost' || $self->host eq '127.0.0.1'){
            # our good friend ab refuses to resolve localhost, so you
            # have to use 127.0.0.1, and then you need two routes.
            push @hosts, qw/localhost 127.0.0.1/;
        }
        else {
            push @hosts, $self->host;
        }

        my $id = 1; # because we forward-referenced it above
        for my $host (@hosts) {
            my $h = $s->resultset('Host')->create({
                id          => $id++,
                name        => $host,
                matching    => $host,
                server_id   => $server->id,
                maintenance => 0,
            });

            $h->create_related('routes' => {
                path        => '/',
                reversed    => 0,
                target_id   => $handler->id,
                target_type => 'handler',
            });
        }

        $s->resultset('Setting')->create({
            key   => 'upload.temp_store',
            value => $config->{root}.'/upload-XXXXXX',
        });

        1;
    }) or die;
    chdir '/'; # so that unlink will work
    return $s;
}

sub _build_pid {
    my $self = shift;
    my $database = $self->database;
    my $config   = $self->config;

    my $pid = fork;
    if(!$pid){
        chdir '/';
        exec $self->mongrel2_path, $config->{database}, $config->{server_uuid};
    }
    return $pid;
}

sub _build_m2 {
    my $self = shift;
    my $config = $self->config;

    my $ctx = ZeroMQ::Raw::Context->new( threads => 1 );

    return AnyEvent::Mongrel2->with_traits('ParseHeaders', 'WithHandles')->new(
        context           => $ctx,
        request_endpoint  => $config->{send},
        response_endpoint => $config->{recv},
        request_identity  => $config->{handler_uuid},
    );
}

sub _start_app {
    my ($self, $app) = @_;

    return AnyEvent::Mongrel2::PSGI->new(
        mongrel2 => $self->_build_m2,
        app      => $app,
    );
}

sub register_service {
    my ($self, $app) = @_;
    $self->_start_app($app);
}

sub run {
    my ($self, $app) = @_;
    my $pid = $self->pid;
    $SIG{INT} = sub {
        kill 'QUIT', $pid;
    };
    print {*STDERR} "Started Mongrel2 instance as pid $pid\n";

    $self->register_service($app);
    AnyEvent->condvar->recv;
}

__PACKAGE__->meta->make_immutable;
