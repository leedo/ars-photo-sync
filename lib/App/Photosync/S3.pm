package App::Photosync::S3;

use AnyEvent::HTTP ();
use Digest::MD5 qw/md5/;
use Digest::HMAC_SHA1 qw/hmac_sha1/;
use MIME::Base64 qw/encode_base64/;
use URI::Escape;

sub new {
  my ($self, $bucket, @keys) = @_;
  die "need key and secret for S3" unless @keys == 2;
  die "need bucket" unless $bucket;
  return bless {
    bucket => $bucket,
    keys => [@keys],
  };
}

sub list {
  my $cb = pop;
  my ($self, $prefix) = @_;
  my %h = (Date => AnyEvent::HTTP::format_date time);
  $h{Authorization} = $self->sign(GET => "/", "", %h);

  AnyEvent::HTTP::http_request
    GET => "http://$bucket.s3.amazonaws.com/",
    headers => \%h,
    $cb;
}

sub put {
  my $cb = pop;
  my ($self, $path, $body, $type) = @_;
  $path = join "/", map {uri_escape_utf8 $_} $self->{bucket}, split "/", $path;

  my %h = (
    "Content-Md5" => encode_base64(md5($body), ""),
    "Content-Type" => ($type || ""),
    "Date" =>  AnyEvent::HTTP::format_date time,
  );

  $h{Authorization} = $self->sign(PUT => "/$path", $body, %h);

  AnyEvent::HTTP::http_request
    PUT => "http://s3.amazonaws.com/$path",
    headers => \%h,
    body => $body,
    $cb;
}

sub sign {
  my ($self, $method, $path, $body, %h) = @_;
  my ($key, $secret) = @{$self->{keys}};

  my $sig = hmac_sha1
    join("\n", $method, @h{qw/Content-Md5 Content-Type Date/}, $path),
    $secret;

  return "AWS $key:".encode_base64($sig, "");
}

1;
