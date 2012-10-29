package App::Photosync;

use v5.12;

use Cwd;
use File::Find;
use Mac::FSEvents;
use AnyEvent;
use AnyEvent::HTTP ();
use Digest::MD5 qw/md5/;
use Digest::HMAC_SHA1 qw/hmac_sha1/;
use MIME::Base64 qw/encode_base64/;

sub new {
  my ($class, %args) = @_;

  for (qw/source dest secret key/) {
    die "$_ is required" unless defined $args{$_};
  }

  return bless {
    source   => Cwd::abs_path($args{source}),
    dest     => $args{dest},
    aws      => [ @args{qw/key secret/} ],
    seen     => {},
    cv       => AE::cv,
    filter   => sub {
      my $f = shift;
      -f $f && $f =~ /(?:jpg|png|gif)$/i && (stat($f))[7] > 0;
    },
  }, $class;
}

sub run {
  my $self = shift;
  $self->{cv}->begin;
  $self->scan_source;

  say "watching $self->{source}";
  say "uploading to $self->{dest}";

  my $fs = Mac::FSEvents->new({path => $self->{source}});

  my $io = AE::io $fs->watch, 0, sub {
    $self->handle_event;
  };

  my $sig = AE::signal INT => sub {
    $self->{cv}->end
  };

  $self->{cv}->recv;
}

sub handle_event {
  my $self = shift;
  my ($add, $del) = $self->scan_source;
  $self->upload_file($_) for @$add;
}

sub scan_source {
  my $self = shift;
  my (%all, @add, @del);

  File::Find::find sub {
    my $path = $File::Find::name;
    return unless $self->{filter}->($path);
    push @add, $path unless $self->{seen}{$path};
    $all{$path} = 1;
  }, $self->{source};

  foreach my $path (keys %{$self->{seen}}) {
    push @del, $path unless $all{$path};
  } 

  $self->{seen} = \%all;
  return (\@add, \@del);
}

sub upload_file {
  my ($self, $path) = @_;

  my $remote = $path;
  $remote =~ s/^\Q$self->{source}\E/$self->{dest}/;

  say "uploading $path to $remote";

  my $body = do {
    open(my $fh, '<', $path) or die "unable to read image: $!";
    local $/;
    <$fh>;
  };

  my ($key, $secret) = @{$self->{aws}};
  my %h = (
    "Content-Md5" => encode_base64(md5($body), ""),
    "Content-Type" => "image/jpeg",
    "Date" =>  AnyEvent::HTTP::format_date time,
  );

  my $sig = hmac_sha1
    join("\n", "PUT", @h{qw/Content-Md5 Content-Type Date/}, $remote),
    $secret;

  $h{Authorization} = "AWS $key:".encode_base64($sig, "");

  $self->{cv}->begin;

  AnyEvent::HTTP::http_request
    PUT => "http://s3.amazonaws.com$remote",
    headers => \%h,
    body => $body,
    sub {
      my ($body, $headers) = @_;
      $self->{cv}->end; 
    };
}

1;
