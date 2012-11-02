package App::Photosync::Worker;

use v5.12;
use Mac::FSEvents ':flags';
use AnyEvent;
use AnyEvent::Util ();
use AnyEvent::AIO;
use IO::AIO;
use App::Photosync::S3;
use List::Util qw/first/;

sub new {
  my ($class, %args) = @_;
  my @required = qw/source event s3 watermark cv/;

  for (@required) {
    die "$_ is required" unless defined $args{$_};
  }

  return bless {
    log       => $args{log} || sub { warn @_ },
    filter    => $args{filter} || sub {
      $_[0] =~ /\.(?:jpe?g|png|gif)$/i;
    },
    map {$_ => $args{$_}} @required
  }, $class;
}

sub log {
  my $self = shift;
  $self->{log}->(__PACKAGE__.": $_") for @_;
}

sub start {
  my $self = shift;
  $self->{cv}->begin;
  $self->log("starting", "scanning $self->{source}, this could take a while");

  $self->{scanner} = scan_dir($self->{source}, $self->{filter}, sub {
    my $matches = shift;
    $self->{seen} = map {$_ => 1} @$matches;;
    $self->log("monitoring $self->{source} for changes");
    my ($r) = split /\./, qx{uname -r};
    my $fs = $self->{fs} = Mac::FSEvents->new({
      path => $self->{source},
      latency => 0.5,
      flags => $r > 11 ? FILE_EVENTS : NONE,
    });

    $self->{io} = AE::io $fs->watch, 0, sub {
      $self->handle_event($_) for $fs->read_events;
    };
  });
}

sub stop {
  my $self = shift;
  $self->{cv}->end;
  $self->log("stopped");
  delete $self->{io};
  $self->{fs}->stop if $self->{fs};
  $self->{scanner}->croak("canceled") if $self->{scanner};
}

sub handle_event {
  my ($self, $event) = @_;
  my $path = $event->path;
  my $add = $self->check_path($path);
  for my $path (@$add) {
    $self->{seen}{$path} = 1;
    $self->queue_image($path);
  }
}

sub queue_image {
  my ($self, $path) = @_;
  $self->{queue}{$path} ||= {
    time => time,
    size => (stat($path))[9],
    watcher => AE::timer 0.25, 0.25, sub {
      my $info = $self->{queue}{$path};
      my $size = (stat($path))[9];
      if ($info->{size} == $size) {
        delete $self->{queue}{$path};
        $self->handle_image($path);
        return;
      }
      $self->{queue}{$path}{size} = $size;
    }
  };
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

sub check_file {
  my ($self, $f) = @_;
  -f $f && !exists $self->{seen}{$f} && $self->{filter}->($f);
}

sub check_path {
  my ($self, $path) = @_;

  if (-f $path) {
    return [$self->check_file($path) ? $path : ()];
  }
  elsif (-d $path) {
    $path =~ s/\/$//; #trailing slash
    opendir my $fh, $path;

    return [ 
      grep {$self->check_file($_) }
      map { "$path/$_" }
      readdir $fh
    ];
  }
  elsif (!-e $path) {
    delete $self->{seen}{$path};
  }

  return [];
}

sub scan_dir {
  my ($path, $filter, $cb) = @_;
  my (@queue, @matches);
  my $cv = AE::cv;

  my $enqueue = sub {
    $cv->begin;
    push @queue, shift;
  };

  $enqueue->($path);

  my $scan = sub {
    my $path = shift;
    aio_scandir $path, 0, sub {
      my ($dirs, $nondirs) = @_;
      for (@$nondirs) {
        push @matches, "$path/$_" if $filter->("$path/$_");
      }
      $enqueue->("$path/$_") for @$dirs;
      $cv->end;
    };
  };

  my $t = AE::idle sub {
    if (my $dir = pop @queue) {
      $scan->($dir);
    }
  };

  $cv->cb(sub {
    eval {shift->recv};
    undef $t;
    if ($@) {
      warn "scanner stopped";
      return;
    }
    $cb->(\@matches);
  });

  return $cv;
}

1;
