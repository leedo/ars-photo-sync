package App::Photosync::Worker;

use File::Find;
use Mac::FSEvents;
use AnyEvent;
use AnyEvent::Util ();
use App::Photosync::S3;

sub new {
  my ($class, %args) = @_;

  for (qw/source event s3 cv/) {
    die "$_ is required" unless defined $args{$_};
  }

  return bless {
    source    => $args{source},
    watermark => $args{watermark},
    event     => $args{event},
    s3        => $args{s3},
    seen      => {},
    cv        => $args{cv},
    log       => $args{log} || sub { warn @_ },
    filter    => sub {
      my $f = shift;
      -f $f && $f =~ /\.(?:jpe?g|png|gif)$/i;
    },
  }, $class;
}

sub log {
  my $self = shift;
  $self->{log}->(__PACKAGE__.": $_") for @_;
}

sub start {
  my $self = shift;
  $self->{cv}->begin;
  $self->log("starting", "scanning $self->{source}");

  File::Find::find(sub {
    $self->{seen}{$File::Find::name} = (stat($File::Find::name))[9];
  }, $self->{source});

  $self->log("monitoring $self->{source} for changes");

  my $fs = $self->{fs} = Mac::FSEvents->new({
    path => $self->{source},
    latency => 0.5,
  });

  $self->{io} = AE::io $fs->watch, 0, sub {
    $self->handle_event($_) for $fs->read_events;
  };
}

sub stop {
  my $self = shift;
  $self->{cv}->end;
  $self->log("stopped");
  $self->{fs}->stop;
  delete $self->{io};
}

sub handle_event {
  my ($self, $event) = @_;
  $self->log("got a filesystem event in " . $event->path);
  my $add = $self->scandir($event->path);
  $self->handle_image($_) for @$add;
}

sub handle_image {
  my ($self, $path) = @_;

  $self->log("resizing $path");
  my @cmd = (qw/convert -auto-orient -resize 640x480^/, $path, '-');

  $self->{cv}->begin;
  my $cv = AnyEvent::Util::run_cmd [@cmd],
    "<"  => "/dev/null",
    "1>" => \my $image,
    "2>" => \my $error;

  $cv->cb(sub {
    $self->{cv}->end;
    my $e = shift->recv;

    if ($e) {
      $self->log("image resize failed $error");
      return;
    }

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
      my $e = shift->recv;

      if ($e) {
        $self->log("image resize failed $error");
        return;
      }

      $path =~ s/^\Q$self->{source}\E/$self->{event}\/images/;
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

sub scandir {
  my ($self, $dir) = @_;
  $dir =~ s/\/$//; #trailing slash
  opendir my $fh, $dir;

  return [ 
    grep {
      my $mtime = (stat($_))[9];
      my $prev = $self->{seen}{$_} || 0;
      $self->{seen}{$_} = $mtime;
      $prev != $mtime;
    }
    grep { $self->{filter}->($_) }
     map { "$dir/$_" }
    readdir $fh
  ];
}

1;
