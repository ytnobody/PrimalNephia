package Nephia::Setup;
use strict;
use warnings;
use Class::Load ':all';
use File::Spec;
use Path::Class;
use Cwd;
use Carp;

sub new {
    my ( $class, %opts ) = @_;
    my $self = bless { %opts }, $class;

    $self->{roles} ||= [];
    map { load_class( 'Nephia::Setup::'.$_ ) } @{$self->{roles}};

    return $self;
}

sub create {
    my ( $self, $appname ) = @_;

    my $approot = approot( $appname );
    $approot->mkpath( 1, 0755 );
    map {
        $approot->subdir($_)->mkpath( 1, 0755 );
    } qw( lib etc view root root/static t );

    psgi_file( $approot, $appname );

    my @apppath = split(/::/, $appname. '.pm');
    my $appfile = pop( @apppath );

    $approot->subdir('lib', @apppath)->mkpath( 1, 0755 ) if @apppath;
    push @apppath, $appfile;

    app_class_file( $approot, \@apppath, $appname );
    index_template_file( $approot );
    css_file( $approot );
    makefile( $approot, $appname );
    basic_test_file( $approot, $appname );
}

sub approot {
    my ( $appname ) = @_;
    $appname =~ s/::/-/g;
    return dir( File::Spec->catfile( getcwd(), $appname ) );
}

sub psgi_file {
    my ( $approot, $appname ) = @_;
    my $body = <<EOF;
use strict;
use warnings;
use FindBin;

use lib ("\$FindBin::Bin/lib", "\$FindBin::Bin/extlib/lib/perl5");
use $appname;
$appname->run;
EOF
    $approot->file( 'app.psgi' )->spew( $body );
}

sub app_class_file {
    my ( $approot, $apppath, $appname ) = @_;
    my $name = $appname; $name =~ s/::/-/g;
    my $body = <<EOF;
package $appname;
use strict;
use warnings;
use Nephia;

our \$VERSION = 0.01;

path '/' => sub {
    my \$req = shift;
    return {
        template => 'index.tx',
        title => '$name',
    };
};

1;
__END__

=head1 NAME

$appname - Web Application

=head1 SYNOPSIS

  \$ plackup

=head1 DESCRIPTION

$appname is web application based Nephia.

=head1 AUTHOR

clever guy

=head1 SEE ALSO

Nephia

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
EOF
    $approot->file( 'lib', @$apppath )->spew( $body );
}

sub index_template_file {
    my $approot = shift;
    my $body = <<EOF;
<html>
<head>
  <script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jquery/1.7.2/jquery.min.js"></script>
  <script type="text/javascript" src="http://ajax.googleapis.com/ajax/libs/jqueryui/1.8.18/jquery-ui.min.js"></script>
  <link rel="stylesheet" href="/static/style.css" />
  <link rel="shortcut icon" href="/static/favicon.ico" />
  <title><: \$title :> - powerd by Nephia</title>
</head>
<body>
  <div class="title">
    <h1><: \$title :></h1>
  </div>
  <address class="generated-by">Generated by Nephia</address>
</body>
</html>
EOF
    $approot->file('view', 'index.tx')->spew( $body );
}

sub css_file {
    my $approot = shift;
    my $body = <<EOF;
body {
    background: #45484d; /* Old browsers */
    background: -moz-linear-gradient(top,  #45484d 0%, #000000 100%); /* FF3.6+ */
    background: -webkit-gradient(linear, left top, left bottom, color-stop(0%,#45484d), color-stop(100%,#000000)); /* Chrome,Safari4+ */
    background: -webkit-linear-gradient(top,  #45484d 0%,#000000 100%); /* Chrome10+,Safari5.1+ */
    background: -o-linear-gradient(top,  #45484d 0%,#000000 100%); /* Opera 11.10+ */
    background: -ms-linear-gradient(top,  #45484d 0%,#000000 100%); /* IE10+ */
    background: linear-gradient(to bottom,  #45484d 0%,#000000 100%); /* W3C */
    filter: progid:DXImageTransform.Microsoft.gradient( startColorstr='#45484d', endColorstr='#000000',GradientType=0 ); /* IE6-9 */
    color: #eed;
    text-shadow: 3px 3px 3px #000;
}

div.title {
    width: 80%;
    margin: auto;
    margin-top: 20px;
    background: #ff5db1; /* Old browsers */
    background: -moz-linear-gradient(top,  #ff5db1 0%, #ef017c 100%); /* FF3.6+ */
    background: -webkit-gradient(linear, left top, left bottom, color-stop(0%,#ff5db1), color-stop(100%,#ef017c)); /* Chrome,Safari4+ */
    background: -webkit-linear-gradient(top,  #ff5db1 0%,#ef017c 100%); /* Chrome10+,Safari5.1+ */
    background: -o-linear-gradient(top,  #ff5db1 0%,#ef017c 100%); /* Opera 11.10+ */
    background: -ms-linear-gradient(top,  #ff5db1 0%,#ef017c 100%); /* IE10+ */
    background: linear-gradient(to bottom,  #ff5db1 0%,#ef017c 100%); /* W3C */
    filter: progid:DXImageTransform.Microsoft.gradient( startColorstr='#ff5db1', endColorstr='#ef017c',GradientType=0 ); /* IE6-9 */
    padding: 10px 30px;
    border-radius: 20px;
    box-shadow: 7px 10px 30px #000;
    color: #eed;
    text-shadow: 3px 3px 3px #000;
}

address.generated-by {
    width: 80%;
    padding: 0px 30px;
    margin: auto;
    margin-top: 20px;
    text-align: right;
    font-style: normal;
}

EOF
    $approot->file('root', 'static', 'style.css')->spew( $body );
}

sub makefile {
    my ( $approot, $appname ) = @_;
    my $apppath = File::Spec->catfile( 'lib', split(/::/, $appname. '.pm') );
    my $body = <<EOF;
use inc::Module::Install;
all_from '$apppath';

requires 'Nephia' => 0.01;

tests 't/*.t';

test_requires 'Test::More';

WriteAll;
EOF
    $approot->file('Makefile.PL')->spew( $body );
}

sub basic_test_file {
    my ( $approot, $appname ) = @_;
    my $body = <<EOF;
use strict;
use warnings;
use Test::More;
BEGIN {
    use_ok( '$appname' );
}
done_testing;
EOF
    $approot->file('t','001_basic.t')->spew( $body );
}

1;
