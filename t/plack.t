use strict;
use warnings;
use Test::More;
use Plack::Test::Suite;
use Path::Class;
use File::Which;

my $m2sh = which('m2sh');
ok -x $m2sh, "m2sh exists at $m2sh";
unlink 'm2.pid'; # why?

my $port = 9019;
my $id = 'a05ede3f-87cb-4e48-8d5a-53c2c29832de';
my $uuid = '5b8235cc-5473-4b45-a1d3-d3b16fb1f07b';
my $s = 'tcp://127.0.0.1:9020';
my $r = 'tcp://127.0.0.1:9021';

my $config = file('mongrel2.conf');
my $database = file('config.sqlite');
my $ch = $config->openw;
print {$ch} <<"EOF";
h = Handler( send_spec="$s"
           , send_ident="$id"
           , recv_spec="$r"
           , recv_ident=""
           )

routes = { "/": h }

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

system($m2sh, 'load', '-db', $database, '-config', $config);

ok -e $database, "created $database ok";

if(fork){
    diag "waiting a bit for mongrel2 to start up";

    Plack::Test::Suite->run_server_tests(
        'AnyEvent::Mongrel2', $port, $port,
        request_identity  => $id,
        request_endpoint  => $s,
        response_endpoint => $r,
    );

    done_testing;
}
else {
    exec($m2sh, 'start', '-db', $database, '-every');
}

END {
    unlink $config;
    unlink $database;

    my $pid = eval { file('m2.pid')->slurp } || file('/tmp/m2.pid')->slurp;
    chomp $pid;
    diag "killing $pid";
    kill 9, $pid;
    unlink file('m2.pid'), file('/tmp/m2.pid');
}
