package App::Photosync::Launcher;

use v5.12;
use AnyEvent;
use AnyEvent::Util ();
use App::Photosync::S3;
use App::Photosync::HTTPD;

sub launch {
  my ($class, %args) = @_;
  
  my $s3 = App::Photosync::S3->new(@args{qw/bucket key secret/});
  my $httpd = App::Photosync::HTTPD->new(%args, s3 => $s3);

  my $t; $t = AE::timer 1, 0, sub {
    undef $t;
    AnyEvent::Util::run_cmd ["open","http://localhost:$args{port}"];
  };

  return $httpd;
}

1;
