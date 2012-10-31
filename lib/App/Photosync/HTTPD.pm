package App::Photosync::HTTPD;

use v5.12;
use JSON;
use AnyEvent::HTTPD;
use Text::MicroTemplate::File;
use App::Photosync::Worker;

sub new {
  my ($class, %args) = @_;

  for (qw/watermark bucket port key secret/) {
    die "$_ is required" unless defined $args{$_};
  }

  # some defaults for worker
  $args{source} = "$ENV{HOME}/Pictures"
    unless defined $args{source};

  $args{event} = "test"
    unless defined $args{event};

  my $s3 = App::Photosync::S3->new(@args{qw/bucket key secret/});
  my $httpd = AnyEvent::HTTPD->new(port => $args{port});
  my $self = bless {
    options => {%args},
    s3      => $s3,
    httpd   => $httpd,
    cv      => AE::cv,
    template => Text::MicroTemplate::File->new(
      include_path => ["share/templates"],
    ),
  }, $class;

  $httpd->reg_cb(
    "/options"  => sub { $self->options(@_) },
    "/start"    => sub { $self->start(@_) },
    "/stop"     => sub { $self->stop(@_) },
    "/shutdown" => sub { $self->shutdown(@_) },
    "/dirs"     => sub { $self->homedir(@_) },
    "/"         => sub { $self->html(@_) },
    ""          => sub { $self->default(@_) },
  );

  $self->log("starting http server");
  return $self;
}

sub listen {
  my $self = shift;
  $self->{cv}->begin;
  say "Location: http://localhost:".$self->{options}{port};
  $self->{cv}->recv;
}

sub default {
  my ($self, $httpd, $req) = @_;
  $self->success($req);
}

sub html {
  my ($self, $httpd, $req) = @_;
  $req->respond({
    content => [
      "text/html",
      $self->{template}->render_file("index.html", $self->{options}, $self->{log})
    ]
  });
}

sub start {
  my ($self, $httpd, $req) = @_;

  if ($self->{worker}) {
    $self->error($req, "worker already started");
    return;
  }

  $self->{cv}->begin;

  $self->{worker} = App::Photosync::Worker->new(
    cv => $self->{cv},
    log => sub { $self->log(@_) },
    s3 => $self->{s3},
    %{$self->{options}}
  );

  $self->{worker}->start;
  $self->success($req);
}

sub stop {
  my ($self, $httpd, $req) = @_;
  if (!$self->{worker}) {
    $self->error($req, "worker already stopped");
    return;
  }
  $self->log("stopping worker");
  $self->{worker}->stop;
  delete $self->{worker};
  $self->success($req);
}

sub options {
  my ($self, $httpd, $req) = @_;

  if ($req->method eq "POST") {
    $self->{options} = { map {$_ => $req->parm($_)} $req->params };
    $req->respond({redirect => "/"});
    return;
  }

  $self->success($req, $self->{options});
}

sub shutdown {
  my ($self, $httpd, $req) = @_;
  $self->log("shutting down");
  $self->success($req);
  $self->{worker}->stop if $self->{worker};
  $self->{cv}->end;
}

sub log {
  my ($self, $message) = @_;
  push @{$self->{log}}, $message;
}

sub respond {
  my ($self, $req, $success, $data) = @_;
  $req->respond({
    content => ["text/json", encode_json {
      success => $success,
      $data ? (data => $data) : (),
      log => $self->{log},
      working => $self->{worker} ? JSON::true : JSON::false,
    }]
  });
}

sub success {
  my ($self, $req, $data) = @_;
  $self->respond($req, JSON::true, $data);
}

sub error {
  my ($self, $req, $msg) = @_;
  $self->log($msg || "unknown error");
  $self->respond($req, JSON::false);
}

1;
