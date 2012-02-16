package Net::Flowdock::Stream;
use Moose;

use JSON;
use MIME::Base64;
use Net::HTTPS::NB;

has token => (
    is  => 'ro',
    isa => 'Str',
);

has email => (
    is  => 'ro',
    isa => 'Str',
);

has password => (
    is  => 'ro',
    isa => 'Str',
);

has flows => (
    traits   => ['Array'],
    isa      => 'ArrayRef[Str]',
    required => 1,
    handles  => {
        flows => 'elements',
    },
);

has socket_timeout => (
    is      => 'ro',
    isa     => 'Num',
    default => 0.01,
);

has _socket => (
    is  => 'rw',
    isa => 'Net::HTTPS::NB',
);

has _readbuf => (
    traits  => ['String'],
    is      => 'rw',
    isa     => 'Str',
    default => '',
    handles => {
        _append_readbuf => 'append',
    },
);

has _events => (
    is      => 'rw',
    isa     => 'ArrayRef[HashRef]', # XXX make these into objects
    default => sub { [] },
);

sub BUILD {
    my $self = shift;

    my $auth;
    if (my $token = $self->token) {
        $auth = $token;
    }
    elsif (my ($email, $pass) = ($self->email, $self->password)) {
        $auth = "$email:$pass";
    }
    else {
        die "You must supply either your token or your email and password";
    }

    my $s = Net::HTTPS::NB->new(Host => 'stream.flowdock.com');
    my $flows = join(',', $self->flows);
    $s->write_request(
        GET => "/flows?filter=$flows" =>
        Authorization => 'Basic ' . MIME::Base64::encode($auth),
        Accept        => 'application/json',
    );

    my ($code, $message, %headers) = $s->read_response_headers;
    die "Unable to connect: $message"
        unless $code == 200;

    $self->_socket($s);
}

sub get_next_event {
    my $self = shift;

    return unless $self->_socket_is_readable;

    $self->_read_next_chunk;

    return $self->_process_readbuf;
}

sub _socket_is_readable {
    my $self = shift;

    my ($rin, $rout) = ('');
    vec($rin, fileno($self->_socket), 1) = 1;

    my $res = select($rout = $rin, undef, undef, $self->socket_timeout);

    if ($res == -1) {
        return if $!{EAGAIN} || $!{EINTR};
        die "Error reading from socket: $!";
    }

    return if $res == 0;

    return 1 if $rout;

    return;
}

sub _read_next_chunk {
    my $self = shift;

    my $nbytes = $self->_socket->read_entity_body(my $buf, 4096);
    if (!defined $nbytes) {
        return if $!{EINTR} || $!{EAGAIN};
        die "Error reading from server";
    }
    die "Disconnected" if $nbytes == 0;
    return if $nbytes == -1;

    $self->_append_readbuf($buf);
}

sub _process_readbuf {
    my $self = shift;

    if ((my $buf = $self->_readbuf) =~ s/^([^\x0d]*)\x0d//) {
        my $chunk = $1;
        $self->_readbuf($buf);
        return decode_json($chunk);
    }

    return;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
