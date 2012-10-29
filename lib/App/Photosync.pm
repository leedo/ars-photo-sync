package App::Photosync;

use v5.12;
use Cwd;
use File::Find;
use Getopt::Long;
use Mac::FSEvents;
use AnyEvent;
use AnyEvent::HTTP;
use Digest::MD5 qw/md5_hex/;
use Digest::HMAC_SHA1 qw/hmac_sha1_hex/;
use MIME::Base64 qw/encode_base64/;

sub new {
  my $class = shift;
  my ($source, $dest, $secret, $key);

  GetOptions(
    "source=s"   => \$source,
    "dest=s"     => \$dest,
    "secret=s"   => \$secret,
    "key=s"      => \$key,
  );

  die "must provide source"   unless $source;
  die "must provide dest"     unless $dest;
  die "must provide aws keys" unless $secret and $key;

  return bless {
    source   => Cwd::abs_path($source),
    dest     => $dest,
    seen     => {},
    cv       => AE::cv,
    filter   => sub {
      my $f = shift;
      -f $f && $f =~ /(?:jpg|png}gif)$/;
    },
  }, $class;
}

sub run {
  my $self = shift;
  $self->{cv}->begin;

  say "watching $self->{source}";
  say "uploading to $self->{dest}";

  $self->scan_source;

  my $fs = Mac::FSEvents->new({
    path => $self->{source},
  });

  my $io = AE::io $fs->watch, 0, sub {
    $self->handle_event($_) for $fs->read_events
  };

  my $sig = AE::signal INT => sub {
    $self->{cv}->end
  };

  $self->{cv}->recv;
}

sub handle_event {
  my ($self, $event) = @_;
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
  $remote =~ s/^\Q$self->{source}\E//;

  my $body = do {
    local $/;
    open my $fh, '<', $path
      or die "unable to read image: $!";
    <$fh>;
  };

  my %h = (
    "Content-Md5" => md5_hex($body),
    "Content-Type" => "image/jpeg",
    "Date" => scalar(localtime(time)),
  );

  my $url = "http://s3.amazonaws.com/$self->{dest}";
  my $sig = hmac_sha1_hex join "\n", "PUT", @h{qw/Content-Md5 Content-Type Date/};
  $h{Authorization} = join ":", "AWS $self->{key}", encode_base64 $sig;

  $self->{cv}->begin;

  http_request PUT => "$url/$remote", %h, sub {
    my ($body, $headers) = @_;
    $self->{cv}->end; 
  };
}

1;
