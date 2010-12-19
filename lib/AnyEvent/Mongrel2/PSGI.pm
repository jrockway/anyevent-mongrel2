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

# override if you want different parsing
sub _decode_headers {
    my ($self, $headers_str) = @_;

    my (%mongrel, %http);
    # TODO: parse mongrel request headers as an array, not as a dict.
    my @headers = %{ decode_json($headers_str) };
    while (@headers) {
        my $key   = shift @headers;
        my $value = shift @headers // confess 'invalid header array: odd';

        if(uc $key eq $key){
            $mongrel{lc $key} = $value;
        }
        else {
            exists $http{$key}
                ? $http{$key} .= ", $value"
                : $http{$key} = $value;
        }
    }

    return {
        mongrel => \%mongrel,
        http    => \%http,
    };
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
    my ($self, $req) = @_;
    # TODO: if it's an upload, open the actual file?
    open my $fh, '<', \$req->{body} or die "cannot open body as scalar: $!";
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

# this is basically a disconnect event, which PSGI does not understand
# or care about.
sub handle_json {}

sub handle_request {
    my ($self, $m2, $req) = @_;

    my ($uuid, $id) = ($req->{uuid}, $req->{id});
    my $headers = $self->_decode_headers($req->{headers});
    my %env = $self->_http_headers($headers->{http});

    if($headers->{mongrel}{method} eq 'JSON'){
        $self->handle_json($req->{body});
        return;
    }

    my $host = $headers->{http}{host} || 'unknown.invalid:80';
    my ($h, $p) = split /:/, $host;
    $h ||= 'unknown.invalid';
    $p ||= 80;
    $env{SERVER_NAME} = $h;
    $env{SERVER_PORT} = $p;

    $env{REQUEST_METHOD}  = delete $headers->{mongrel}{method};
    $env{SCRIPT_NAME}     = delete $headers->{mongrel}{path};
    $env{PATH_INFO}       = uri_unescape($req->{path});
    $env{REQUEST_URI}     = delete $headers->{mongrel}{uri};
    $env{QUERY_STRING}    = delete $headers->{mongrel}{query};
    $env{SERVER_PROTOCOL} = delete $headers->{mongrel}{version};
    for my $k (keys %{$headers->{mongrel}}){
        # future-proof!  this gets stuff like pattern
        $env{"mongrel.$k"} = $headers->{mongrel}{$k};
    }

    $env{'psgi.version'}      = [1,0];
    $env{'psgi.url_scheme'}   = 'http'; # XXX
    $env{'psgi.errors'}       = $self->error_stream;
    $env{'psgi.input'}        = $self->_handleize_body($req);
    $env{'psgi.multithread'}  = $self->coro;
    $env{'psgi.multiprocess'} = 0; # XXX: could be
    $env{'psgi.run_once'}     = 0;
    $env{'psgi.nonblocking'}  = 1;
    $env{'psgi.streaming'}    = 1;
    $env{'mongrel.uuid'}      = $uuid;
    $env{'mongrel.id'}        = $id;

    my $wrap = sub { $_[0]->() };
    $wrap = \&Coro::async if $self->coro;

    $wrap->(sub {
        my $res = try {
            $self->app->(\%env);
        }
        catch {
            [ 500, [ 'Content-Type' => 'text/plain' ], [ 'Exception: ', $_ ] ];
        };

        my $is_closed = 0;

        my $send = sub {
            my $data = join '', @_;
            confess 'already closed connection'
                if $is_closed != 0;

            $self->mongrel2->send_response($data, $uuid, $id);
        };

        my $close = sub {
            confess 'already closed connection'
                if $is_closed != 0;

            $send->('');
        };

        my $send_headers = sub {
            my ($code, $headers, $body) = @_;
            my $msg = join ' ', $env{SERVER_PROTOCOL}, $code, status_message($code);
            $msg .= "\r\n".$self->_join_headers(@{$headers})."\r\n";

            if(_HANDLE($body) || blessed $body){
                $send->($msg);
                my $line;
                while(defined($line = $body->getline)){
                    $send->($line);
                }
                $body->close;
            }
            elsif(_ARRAYLIKE($body)){
                $send->($msg, join '', @$body);
            }
            else {
                confess "Bad body: must be ARRAYLIKE or HANDLE, not '$_'";
            }
        };

        if(_ARRAYLIKE($res)){
            $send_headers->(@$res);
            $close->();
        }
        elsif(_CODELIKE($res)){
            my $respond = sub {
                my $arg = shift;
                confess 'value passed by app to respond callback is not an array!'
                    unless _ARRAYLIKE($arg);

                my ($code, $headers, $body) = @$arg;
                if($body){
                    $send_headers->($code, $headers, $body);
                    $close->();
                    return;
                }

                $send_headers->($code, $headers, []);
                return AnyEvent::Mongrel2::PSGI::Writer->new(
                    $send,
                    sub {
                        my $cb = shift;
                        $self->mongrel2->defer_response(
                            $cb, $uuid, $id,
                        );
                    },
                    $close,
                );
            };
            $res->($respond);
        }
        else {
            confess "Your app must return a CODE or ARRAY ref, not $res";
        }
    });
}

__PACKAGE__->meta->make_immutable;
