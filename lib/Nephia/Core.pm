package Nephia::Core;
use strict;
use warnings;

use parent 'Exporter';
use Nephia::Request;
use Nephia::Response;
use Nephia::GlobalVars;
use Nephia::Context;
use Nephia::PluginLoader;
use Plack::Builder;
use Router::Simple;
use Nephia::View;
use JSON ();
use Encode;
use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Module::Load ();

our @EXPORT = qw[ get post put del path req res param path_param nip run config app nephia_plugins base_dir cookie set_cookie ];
our $CONTEXT;

Nephia::GlobalVars->set(
    mapper   => Router::Simple->new,
    view     => undef,
    config   => {},
    charset  => Encode::find_encoding('UTF-8')->mime_name,
    app_map  => {},
    app_code => {},
    app_root => undef,
    json     => JSON->new->utf8,
);

sub _path {
    my ( $path, $code, $methods, $target_class ) = @_;
    my $caller = caller();
    my $app_class = caller(1);
    my ($app_map, $app_code, $mapper) = Nephia::GlobalVars->get(qw/app_map app_code mapper/);

    my $sub_app_map = $target_class ? $app_map->{$target_class} : undef;
    if ($sub_app_map && exists $sub_app_map->{path}) {
        # setup for submapping one more
        $app_code->{$target_class} ||= {};
        if (!exists $app_code->{$target_class}{$path}) {
            $app_code->{$target_class}{$path} = {
                code => $code,
                methods => $methods,
            };
        }

        $path =~ s!^/!!g;
        my @paths = ($app_map->{$target_class}{path});
        push @paths, $path if length($path) > 0;
        $path = join '/', @paths;
    }

    my $action = _build_action($app_class, $caller, $code);

    $mapper->connect(
        $path,
        { action => $action } ,
        $methods ? { method => $methods } : undef,
    );
}

sub before_action {
    my ($env, $path_param, $next_action) = @_;
    $next_action->($env, $path_param);
}

sub _build_action {
    my ($app_class, $caller, $code) = @_;
    local $CONTEXT = Nephia::Context->new;
    my $action = sub {
        my ($env, $path_param) = @_;
        my $req = $CONTEXT->{req};
        my $res = $code->( $req, $req->path_param );
        return _process_response($res);
    };
    return sub { 
        my ($env, $path_param) = @_;
        my $req = _process_request($env, $path_param);
        $CONTEXT->{app} = $app_class;
        $CONTEXT->{req} = $req;
        no strict qw[ refs subs ];
        no warnings qw[ redefine ];
        local *{$caller."::req"} = sub{ $req };
        local *{$caller."::param"} = sub (;$) {
            my $key = shift;
            $key ? $req->param($key) : $req->parameters;
        };
        local *{$caller."::nip"} = sub (;$) { $req->nip(shift) };
        local *{$caller."::path_param"} = sub (;$) { $path_param };
        my $res = before_action($env, $path_param, $action); 
        return $res;
    };
}

sub _process_request {
    my ($raw_env, $path_param) = @_;
    my $env = process_env($raw_env);
    my $req = Nephia::Request->new($env);
    $req->{path_param} = $path_param;
    $CONTEXT->{cookie} = $req->cookies;
    return $req;
}

sub process_env {
    my $env = shift;
    return $env;
}

sub _render_or_json {
    my $raw_res = shift;
    eval {$raw_res->{template}} ? render($raw_res) : json_res($raw_res);
}

sub _process_response {
    my $raw_res = shift;
    my $res = 
        ref($raw_res) eq 'HASH' ? Nephia::Response->new( @{_render_or_json($raw_res)} ) :
        blessed($raw_res) && $raw_res->isa('Plack::Response') ? $raw_res :
        Nephia::Response->new(@{$raw_res})
    ;
    if ($CONTEXT->{cookie}) {
        for my $key (keys %{$CONTEXT->{cookie}}) {
            $res->cookies->{$key} = $CONTEXT->{cookie}{$key};
        }
    }
    $res = process_response($res);
    if (ref($res->body) eq 'ARRAY') {
        $res->body->[0] = process_content($res->body->[0]);
    }
    else {
        $res->body( process_content($res->body) );
    }
    return $res->finalize;
}

sub process_response {
    my $res = shift;
    return $res;
}

sub process_content {
    my $content = shift;
    return $content;
}

sub _submap {
    my ( $path, $package, $base_class ) = @_;

    my ($app_map, $app_code) = Nephia::GlobalVars->get(qw/app_map app_code/);

    if (!($package =~ s/^\+//g)) {
        $package = join '::', $base_class, $package;
    }

    $app_map->{$package}{path} = $path;
    if (!$app_code->{$package}) {
        Module::Load::load($package);
        $package->import if $package->can('import');
    }
    else {
         for my $suffix_path (keys %{$app_code->{$package}}) {
            my $sub_app_code = $app_code->{$package}->{$suffix_path};
            _path ($suffix_path, $sub_app_code->{code}, $sub_app_code->{methods}, $package);
        }
    }
}

sub get ($&) {
    my ( $path, $code ) = @_;
    _path( $path, $code, ['GET'] );
}

sub post ($&) {
    my ( $path, $code ) = @_;
    _path( $path, $code, ['POST'] );
}

sub put ($&) {
    my ( $path, $code ) = @_;
    _path( $path, $code, ['PUT'] );
}

sub del ($&) {
    my ( $path, $code ) = @_;
    _path( $path, $code, ['DELETE'] );
}

sub path ($@) {
    my ( $path, $code, $methods ) = @_;
    my $caller = caller();
    ref($code) eq "CODE" ? 
        _path($path, $code, $methods, $caller) :
        _submap($path, $code, $caller)
    ;
}

sub res (&) {
    my $code = shift;
    my $res = Nephia::Response->new(200);
    $res->content_type('text/html');
    {
        no strict qw[ refs subs ];
        no warnings qw[ redefine ];
        my $caller = caller();
        map {
            my $method = $_;
            *{$caller.'::'.$method} = sub (@) {
                $res->$method( @_ );
                return;
            };
        } qw[
            status headers body header
            content_type content_length
            content_encoding redirect cookies
        ];
        my @rtn = ( $code->() );
        if ( @rtn ) {
            $rtn[1] ||= [];
            $rtn[2] ||= [];
            $res = [@rtn];
        }
    }
    return $res;
}

sub run {
    my $class = shift;
    my $base_dir = base_dir($class);
    my $config = scalar @_ > 1 ? +{ @_ } : $_[0];
    my $view = Nephia::View->new(($config->{view} ? %{$config->{view}} : ()), template_path => File::Spec->catdir($base_dir, 'view'));

    Nephia::GlobalVars->set(config => $config, view => $view);

    my $root = File::Spec->catfile($base_dir, 'root');
    return builder {
        enable "Static", root => $root, path => qr{^/static/};
        $class->app;
    };
}

sub app {
    my $class = shift;
    my $mapper = Nephia::GlobalVars->get('mapper');
    return sub {
        my $env = shift;
        if ( my $p = $mapper->match($env) ) {
            my $action = delete $p->{action};
            $action->($env, $p);
        }
        else {
            [404, [], ['Not Found']];
        }
    };
}

sub json_res {
    my $res  = shift;
    my $json = Nephia::GlobalVars->get('json');
    my $body = $json->encode( $res );
    return [ 200,
        [
            'Content-type'           => 'application/json',
            'X-Content-Type-Options' => 'nosniff',  ### For IE 9 or later. See http://web.nvd.nist.gov/view/vuln/detail?vulnId=CVE-2013-1297
            'X-Frame-Options'        => 'DENY',     ### Suppress loading web-page into iframe. See http://blog.mozilla.org/security/2010/09/08/x-frame-options/
            'Cache-Control'          => 'private',  ### no public cache
        ],
        [ $body ]
    ];
}

sub render {
    my $res     = shift;
    my $charset = delete $res->{charset} || Nephia::GlobalVars->get('charset');
    my $view    = Nephia::GlobalVars->get('view');
    my $body    = $view->render( $res->{template}, $res );
    return [ 200,
        [ 'Content-type' => "text/html; charset=$charset" ],
        [ Encode::encode( $charset, $body ) ]
    ];
}

sub config (@) {
    Nephia::GlobalVars->set(config => 
        scalar @_ > 1 ? { @_ } :
        ref $_[0] eq 'HASH' ? $_[0] :
        do( $_[0] )
    ) if scalar(@_) > 0;
    return Nephia::GlobalVars->get('config');
};

sub nephia_plugins (@) {
    goto do { Nephia::PluginLoader->can('load') };
}

sub base_dir {
    my $proto = shift || caller;

    $proto =~ s!::!/!g;
    my $base_dir;
    if (my $libpath = $INC{"$proto.pm"}) {
        $libpath =~ s!\\!/!g; # for win32
        $libpath =~ s!(?:blib/)?lib/+$proto\.pm$!!;
        $base_dir = File::Spec->rel2abs($libpath || '.');
    } else {
        $base_dir = File::Spec->rel2abs('.');
    }

    no warnings 'redefine';
    *Nephia::Core::base_dir = sub {
        return $base_dir;
    };

    return $base_dir;
}

sub set_cookie ($$){
    my ($key, $val) = @_;
    $CONTEXT->{cookie}{$key} = $val;
}

sub cookie ($) {
    my $key = shift;
    $CONTEXT->{cookie}{$key};
}

1;
