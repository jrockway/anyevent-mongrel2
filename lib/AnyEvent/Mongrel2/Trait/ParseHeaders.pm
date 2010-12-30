package AnyEvent::Mongrel2::Trait::ParseHeaders;
# ABSTRACT: parse the JSON headers into a perl hash
use Moose::Role;
use true;
use namespace::autoclean;
use JSON;

use 5.010;

sub _decode_headers {
    my ($self, $headers_str) = @_;

    my %headers;
    my %raw_headers = %{ decode_json($headers_str) };
    for my $key (keys %raw_headers){
        my $value = $raw_headers{$key};

        $value = join ', ', @$value if(ref $value);

        exists $headers{$key}
            ? $headers{$key} .= ", $value"
            : $headers{$key} = $value;
    }

    return \%headers;
}

around 'parse_request' => sub {
    my ($orig, $self, @args) = @_;
    my $hash = $self->$orig(@args);

    $hash->{headers} = $self->_decode_headers($hash->{headers});
    return $hash;
};
