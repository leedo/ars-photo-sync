package App::Photosync::Worker;

use File::Find;
use Mac::FSEvents;
use AnyEvent;
use AnyEvent::Util ();
use App::Photosync::S3;

sub new {
  my ($class, %args) = @_;

  for (qw/source event bucket secret key cv/) {
    die "$_ is required" unless defined $args{$_};
  }

  $args{bucket} =~ s{(^/|/$)}{};
  $args{event} =~ s{^/}{};

  return bless {
    source    => $args{source},
    watermark => $args{watermark},
    dest      => "/$args{bucket}/$args{event}/images",
    s3        => App::Photosync::S3->new(@args{qw/key secret/}),
    seen      => {},
    cv        => $args{cv},
    log       => $args{log} || sub { warn @_ },
    filter    => sub {
      my $f = shift;
      -f $f && $f =~ /(?:jpg|png|gif)$/i && (stat($f))[7] > 0;
    },
  }, $class;
}

sub log {
  my $self = shift;
  $self->{log}->($_) for @_;
}

sub start {
  my $self = shift;
  $self->{cv}->begin;

  $self->log("starting");
  $self->log("initial scan");
  $self->scan_source;

  my $fs = $self->{fs} = Mac::FSEvents->new({path => $self->{source}});
  $self->{io} = AE::io $fs->watch, 0, sub {
    $self->log("got a filesystem event");
    $self->handle_event($_) for $fs->read_events;
  };
}

sub stop {
  my $self = shift;
  $self->log("stopped");
  $self->{fs}->stop;
  delete $self->{io};
  $self->{cv}->end;
}

sub handle_event {
  my ($self, $event) = @_;
  my ($add, $del) = $self->scan_source;
  $self->handle_image($_) for @$add;
}

sub handle_image {
  my ($self, $path) = @_;

  $self->log("resizing $path");
  my @cmd = (qw/convert -resize 640x480^/, $path, '-');

  $self->{cv}->begin;
  my $cv = AnyEvent::Util::run_cmd [@cmd],
    "<"  => "/dev/null",
    "1>" => \my $image,
    "2>" => \my $error;

  $cv->cb(sub {
    $self->{cv}->end;
    shift->recv and die "image resize failed $error";

    $self->log("watermarking $path");
    my @cmd = (qw/composite -watermark %30 -gravity southeast/,
              $self->{watermark}, qw/- -/);

    $self->{cv}->begin;
    my $cv = AnyEvent::Util::run_cmd [@cmd],
      "<"  => \$image,
      "1>" => \my $watermarked,
      "2>" => \$error;

    $cv->cb(sub {
      $self->{cv}->end;
      shift->recv and die "image watermark failed $error";

      $path =~ s/^\Q$self->{source}\E/$self->{dest}/;
      $self->{cv}->begin;
      $self->{s3}->put($path, $watermarked, "image/jpeg", sub {
        my ($body, $headers) = @_;
        $self->log("upload complete: $headers->{Status}");
        if ($headers->{Status} != 200) {
          $body =~ s/</&lt;/;
          $body =~ s/>/&gt;/;
          $self->log("$headers->{Reason}<br><pre>$body</pre>");
        }
        $self->{cv}->end; 
      });
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

1;
