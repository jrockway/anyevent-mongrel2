package AnyEvent::Mongrel2::PSGI;
# ABSTRACT: run a PSGI app with AnyEvent::Mongrel2
use Moose;

use AnyEvent::Mongrel2::PSGI::Writer;
use HTTP::Status qw(status_message);
use JSON::XS;
use Params::Util qw(_CODELIKE _ARRAYLIKE _HANDLE);
use Try::Tiny;
use URI::Escape qw(uri_unescape);
use IO::File;

use 5.010;
use true;
use namespace::autoclean;

has 'mongrel2' => (
    is       => 'ro',
    isa      => 'AnyEvent::Mongrel2',
    required => 1,
);

has 'app' => (
    is       => 'ro',
    isa      => 'CodeRef',
    required => 1,
);

has 'error_stream' => (
    is      => 'ro',
    isa     => 'GlobRef',
    default => sub { \*STDERR },
);

has 'coro' => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

sub BUILD {
    my $self = shift;

    if($self->coro){ require Coro }

    $self->mongrel2->handler(sub {
        my ($m2, $req) = @_;
        $self->handle_request($m2, $req);
    });
}

sub _partition_headers {
    my ($self, $headers) = @_;

    my (%mongrel, %http);
    for my $key (keys %$headers){
        if($key eq uc $key){
            $mongrel{lc $key} = $headers->{$key};
        }
        else {
            $http{lc $key} = $headers->{$key};
        }
    }
    return { mongrel => \%mongrel, http => \%http };
}

# translate { foo-bar => 'baz' } to { HTTP_FOO_BAR => 'baz' }
sub _http_headers {
    my ($self, $headers) = @_;
    my %res;
    while(my ($k, $v) = each %$headers){
        $k =~ tr/-/_/;
        $res{uc("HTTP_$k")} = $v;
    }
    # and then some special cases
    $res{CONTENT_TYPE} = delete $res{HTTP_CONTENT_TYPE}
        if exists $res{HTTP_CONTENT_TYPE};

    $res{CONTENT_LENGTH} = delete $res{HTTP_CONTENT_LENGTH}
        if exists $res{HTTP_CONTENT_LENGTH};

    return %res;
}

sub _handleize_body {
    my ($self, $req, $headers) = @_;
    my $fh;
    if(my $file = $headers->{http}{'x-mongrel2-upload-start'}){
        open $fh, '<', $file or die "cannot open upload '$file': $!";
    }
    else {
        open $fh, '<', \$req->{body} or die "cannot open body as scalar: $!";
    }
    return $fh;
}

sub _join_headers {
    my ($self, @headers) = @_;
    my $buf = '';
    while(@headers){
        my $k = shift @headers;
        my $v = shift @headers // confess 'odd headers received from app';
        confess "cannot have newline in header '$k'" if $v =~ /\n/;

        $k = join '-', map { ucfirst($_) } split(/[-_]/, $k);
        $buf .= "$k: $v\r\n";
    }
    return $buf;
}

sub build_env {
    my ($self, $req) = @_;

    my ($uuid, $id) = ($req->{uuid}, $req->{id});
    my $headers = $self->_partition_headers($req->{headers});
    my %env = $self->_http_headers($headers->{http});

    my $host = $headers->{http}{host} || 'unknown.invalid:80';
    my ($h, $p) = split /:/, $host;
    $h ||= 'unknown.invalid';
    $p ||= 80;

    $env{SERVER_NAME} = $h;
    $env{SERVER_PORT} = $p;

    $env{SCRIPT_NAME}     = ''; # was delete $headers->{mongrel}{path}, which is too much
    $env{PATH_INFO}       = uri_unescape($req->{path});
    $env{REQUEST_METHOD}  = delete $headers->{mongrel}{method};
    $env{REQUEST_URI}     = delete $headers->{mongrel}{uri};
    $env{QUERY_STRING}    = delete $headers->{mongrel}{query};
    $env{SERVER_PROTOCOL} = delete $headers->{mongrel}{version};
    for my $k (keys %{$headers->{mongrel}}){
        # future-proof!  this gets stuff like pattern
        $env{"mongrel2.$k"} = $headers->{mongrel}{$k};
    }

    $env{'psgi.version'}      = [1,0];
    $env{'psgi.url_scheme'}   = 'http'; # XXX
    $env{'psgi.errors'}       = $self->error_stream;
    $env{'psgi.input'}        = $self->_handleize_body($req, $headers);
    $env{'psgi.multithread'}  = $self->coro;
    $env{'psgi.multiprocess'} = 0; # XXX: could be
    $env{'psgi.run_once'}     = 0;
    $env{'psgi.nonblocking'}  = 1;
    $env{'psgi.streaming'}    = 1;
    $env{'psgix.io'}          = $req->{handle};
    $env{'mongrel2.uuid'}     = $uuid;
    $env{'mongrel2.id'}       = $id;

    return \%env;
}

sub send_headers {
    my ($self, $env, $code, $headers, $body) = @_;
    my $handle = $env->{'psgix.io'};

    my $msg = join ' ', $env->{SERVER_PROTOCOL}, $code, status_message($code);
    $msg .= "\r\n".$self->_join_headers(@{$headers})."\r\n";

    if(_HANDLE($body) || blessed $body){
        $handle->write($msg);
        my $line;
        while(defined($line = $body->getline)){
            $handle->write($line);
        }
        $body->close;
    }
    elsif(_ARRAYLIKE($body)){
        $handle->write($msg . join('', @$body));
    }
    else {
        confess "Bad body: must be ARRAYLIKE or HANDLE, not '$_'";
    }

    return;
}


sub handle_request {
    my ($self, $m2, $req) = @_;

    my $respond = sub {
        my $env = shift;
        my $res = try {
            $self->app->($env);
        }
        catch {
            [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Exception: ', $_ ] ];
        };

        # note: we are relying on the handle's DEMOLISH method to
        # close the connection for us.  if you change how handles or
        # DEMOLISH work, make sure you send the mongrel2 kill message,
        # the empty string, after sending all headers/body.

        if(_ARRAYLIKE($res)){
            $self->send_headers($env, @$res);
        }
        elsif(_CODELIKE($res)){
            my $respond = sub {
                my $arg = shift;
                confess 'value passed by app to respond callback is not an array!'
                    unless _ARRAYLIKE($arg);

                my ($code, $headers, $body) = @$arg;
                my $body_defined = defined $body;
                $body ||= [];

                $self->send_headers($env, $code, $headers, $body);

                return $env->{'psgix.io'} if !$body_defined; # streaming response
                return;
            };
            $res->($respond);
        }
        else {
            confess "Your app must return a CODE or ARRAY ref, not $res";
        }
    };

    my $env = $self->build_env($req);

    if( $self->coro ){
        Coro::async({ $respond->($env) });
    }
    else {
        $respond->($env);
    }

    return;
}

__PACKAGE__->meta->make_immutable;
