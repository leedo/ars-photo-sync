package App::Photosync::Launcher;

use v5.12;
use AnyEvent;
use AnyEvent::Util ();
use parent "App::Photosync::HTTPD";

sub launch {
  my ($class, %args) = @_;
  
  my $self = $class->SUPER::new(%args);
  my $port = $self->{options}{port};

  my $t; $t = AE::timer 1, 0, sub {
    undef $t;
    AnyEvent::Util::run_cmd "open 'http://localhost:$port'";;
  };

  return $self;
}

1;
