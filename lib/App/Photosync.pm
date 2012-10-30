package App::Photosync;

use v5.12;

use Cwd;
use File::Find;
use Mac::FSEvents;
use AnyEvent;
use AnyEvent::Util ();
use AnyEvent::HTTP ();
use Digest::MD5 qw/md5/;
use Digest::HMAC_SHA1 qw/hmac_sha1/;
use MIME::Base64 qw/encode_base64/;

sub new {
  my ($class, %args) = @_;

  for (qw/source event bucket secret key/) {
    die "$_ is required" unless defined $args{$_};
  }

  $args{bucket} =~ s{(^/|/$)}{};
  $args{event} =~ s{^/}{};

  return bless {
    source    => Cwd::abs_path($args{source}),
    watermark => Cwd::abs_path($args{watermark}),
    dest      => "/$args{bucket}/$args{event}/images",
    bucket    => $args{bucket},
    keys      => [ @args{qw/key secret/} ],
    seen      => {},
    cv        => AE::cv,
    filter    => sub {
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
  say "all done!";
}

sub handle_event {
  my $self = shift;
  my ($add, $del) = $self->scan_source;
  $self->handle_image($_) for @$add;
}

sub handle_image {
  my ($self, $path) = @_;

  my @cmd = (qw/convert -resize 640x480^/, $path, '-');

  $self->{cv}->begin;
  my $cv = AnyEvent::Util::run_cmd [@cmd],
    "<"  => "/dev/null",
    "1>" => \my $image,
    "2>" => \my $error;

  $cv->cb(sub {
    $self->{cv}->end;
    shift->recv and die "image conversion failed $error";

    my @cmd = (qw/composite -watermark %30 -gravity southeast/,
              $self->{watermark}, qw/- -/);

    $self->{cv}->begin;
    my $cv = AnyEvent::Util::run_cmd [@cmd],
      "<"  => \$image,
      "1>" => \my $watermarked,
      "2>" => \$error;

    $cv->cb(sub {
      $self->{cv}->end;
      shift->recv and die "image conversion failed $error";
      $path =~ s/^\Q$self->{source}\E/$self->{dest}/;
      $self->upload_image($path, $watermarked);
    });
  });
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

sub upload_image {
  my ($self, $path, $image) = @_;

  say "uploading $path";

  my ($key, $secret) = @{$self->{keys}};
  my %h = (
    "Content-Md5" => encode_base64(md5($image), ""),
    "Content-Type" => "image/jpeg",
    "Date" =>  AnyEvent::HTTP::format_date time,
  );

  my $sig = hmac_sha1
    join("\n", "PUT", @h{qw/Content-Md5 Content-Type Date/}, $path),
    $secret;

  $h{Authorization} = "AWS $key:".encode_base64($sig, "");

  $self->{cv}->begin;

  AnyEvent::HTTP::http_request
    PUT => "http://s3.amazonaws.com$path",
    headers => \%h,
    body => $image,
    sub {
      my ($body, $headers) = @_;
      $self->{cv}->end; 
    };
}

1;
