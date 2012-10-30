package App::Photosync::S3;

use AnyEvent::HTTP ();
use Digest::MD5 qw/md5/;
use Digest::HMAC_SHA1 qw/hmac_sha1/;
use MIME::Base64 qw/encode_base64/;
use URI::Escape;

sub new {
  my ($self, @keys) = @_;
  die "need key and secret for S3" unless @keys == 2;
  return bless {
    keys => [@keys],
  };
}

sub put {
  my $cb = pop;
  my ($self, $path, $body, $type) = @_;

  my ($key, $secret) = @{$self->{keys}};
  my %h = (
    "Content-Md5" => encode_base64(md5($body), ""),
    "Content-Type" => ($type || ""),
    "Date" =>  AnyEvent::HTTP::format_date time,
  );

  $path = join "/", map {uri_escape_utf8 $_} split "/", $path;
  my $sig = hmac_sha1
    join("\n", "PUT", @h{qw/Content-Md5 Content-Type Date/}, $path),
    $secret;

  $h{Authorization} = "AWS $key:".encode_base64($sig, "");

  AnyEvent::HTTP::http_request
    PUT => "http://s3.amazonaws.com$path",
    headers => \%h,
    body => $body,
    sub {
      my ($body, $headers) = @_;
      $cb->(@_);
    };
}

1;
