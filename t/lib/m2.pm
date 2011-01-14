package t::lib::m2;
use strict;
use warnings;
use true;

use Test::More;
use Sub::Exporter -setup => { exports => ['m2'] };

use POSIX qw(dup2);

my ($called, $config, $database);

sub m2() {
    use Path::Class;
    use File::Which;

    my $m2sh = which('m2sh');
    ok -x $m2sh, "m2sh exists at $m2sh";
    unlink 'm2.pid';            # why?

    my $port = 9019;
    my $id = 'a05ede3f-87cb-4e48-8d5a-53c2c29832de';
    my $uuid = '5b8235cc-5473-4b45-a1d3-d3b16fb1f07b';
    my $s = 'tcp://127.0.0.1:9020';
    my $r = 'tcp://127.0.0.1:9021';

    $config = file('mongrel2.conf');
    $database = file('config.sqlite');
    my $ch = $config->openw;
    print {$ch} <<"EOF";
h = Handler( send_spec="$s"
           , send_ident="$id"
           , recv_spec="$r"
           , recv_ident=""
           )

routes = { "/": h, "\@data": h, "<data": h }

main = Server( uuid="$uuid"
             , access_log="/m2access.log"
             , error_log="/m2error.log"
             , chroot="/tmp"
             , pid_file="/m2.pid"
             , default_host="localhost"
             , port=$port
             , name="test"
             , hosts = [ Host( name="localhost", routes=routes )
                       , Host( name="127.0.0.1", routes=routes )
                       ]
             )

settings = {"zeromq.threads":1,"upload.temp_store":"/tmp/XXXXXX"}

servers = [main]

EOF
    close $ch;

    open my $devnull, '>', '/dev/null' or die "devnull: $!";
    dup2(fileno $devnull, 1) or die "dup2: $!";
    dup2(fileno $devnull, 2) or die "dup2: $!";

    system($m2sh, 'load', '-db', $database, '-config', $config);

    ok -e $database, "created $database ok";
    $called = 1;

    my $pid = fork();
    die "fork failed $!" unless defined $pid;

    if(!$pid){

        exec($m2sh, 'start', '-db', $database, '-every');
    }

    return (
        port              => $port,
        request_identity  => $id,
        request_endpoint  => $s,
        response_endpoint => $r,
    );
}

END {
    return unless $called;
    unlink $config;
    unlink $database;

    my $pid = eval { file('m2.pid')->slurp } || file('/tmp/m2.pid')->slurp;
    chomp $pid;
    diag "killing $pid";
    kill 9, $pid;
    unlink file('m2.pid'), file('/tmp/m2.pid');
}
