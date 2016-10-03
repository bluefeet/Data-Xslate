package Data::Xslate;

=head1 NAME

Data::Xslate - Templatize your data.

=head1 SYNOPSIS

    use Data::Xslate;
    
    my $xslate = Data::Xslate->new();
    
    my $new_data = $xslate->render(
        {
            user => {
                login => 'john',
                email => '<: $login :>@example.com',
                name  => 'John',
            },
            email => {
                to      => '=:user.email',
                subject => 'Hello <: $user.name :>!',
            },
        },
    );

=head1 DESCRIPTION

This module provides a syntax for templatizing data structures.

The most likely use-case is adding some flexibility to configuration
files.

=head1 SUBSTITUTION

    {
        foo => 14,
        bar => '=:foo',
    }
    # { foo=>14, bar=>14 }

This injects the target value.  This can be used for any data type.  For
example we can substitute an array:

    {
        foo => [1,2,3],
        bar => '=:foo',
    }
    # { foo=>[1,2,3], bar=>[1,2,3] }

=head1 TEMPLATING

    {
        foo => 'green',
        bar => 'It is <: $foo :>!',
    }
    # { foo=>'green', bar=>'It is green!' }

The syntax for templating is provided by L<Text::Xslate>, so
there is a lot of power here including being able to do math
and string mangling.

=head1 SCOPE

When using either L</SUBSTITUTION> or L</TEMPLATING> you specify a key to be
included.  This key is found using scope-aware rules where the key is searched for
in a similar fashion to how you'd expect when dealing with lexical variables in
programming.

For example, you can refer to a key in the same scope:

    { a=>1, b=>'=:a' }

You may refer to a key in a lower scope:

    { a=>{ b=>1 }, c=>'=:a.b' }

You may refer to a key in a higher scope:

    { a=>{ b=>'=:c' }, c=>1 }

You may refer to a key in a higher scope that is nested:

    { a=>{ b=>'=:c.d' }, c=>{ d=>1 } }

The logic behind this is pretty flexible, so more complex use cases will
just work like you would expect.

If you'd rather avoid this scoping you can prepend any key with a dot, C<.>, and
it will be looked for at the root hash of the config tree only.

=head1 NESTED KEYS

When setting a key value the key can point deeper into the structure by separating keys with
a dot, C<.>.  Consider this:

    { a=>{ b=>1 }, 'a.b'=>2 }

Which produces:

    { a=>{ b=>2 } }

=cut

use Text::Xslate;
use Types::Standard -types;
use Types::Common::String -types;
use Carp qw( croak );

use Moo;
use strictures 2;
use namespace::clean;

# A tied-hash class used to expose the data as the Xslate
# vars when processing the data.
{
    package Data::Xslate::Vars;

    use base 'Tie::Hash';

    sub TIEHASH {
        my ($class, $sub) = @_;
        return bless {sub=>$sub}, $class;
    }

    sub FETCH {
        my ($self, $key) = @_;

        return $self->{sub}->( $key );
    }
}

# State variables, only used during local() calls to maintane
# state in recursive function calls.
our $XSLATE;
our $VARS;
our $ROOT;
our $NODES;
our $SUBSTITUTION_TAG;
our $PATH_FOR_XSLATE;

around BUILDARGS => sub{
    my $orig = shift;
    my $class = shift;

    my $args = {};
    my $xslate_args = $class->$orig( @_ );

    my @expected_args = qw(
        substitution_tag
    );
    foreach my $arg (@expected_args) {
        next if !exists $xslate_args->{$arg};
        $args->{$arg} = delete $xslate_args->{$arg};
    }
    $args->{_xslate_args} = $xslate_args;

    return $args;
};

has _xslate_args => (
    is => 'ro',
);

=head1 ARGUMENTS

Any arguments you pass to C<new>, which this class does not directly
handle, will be used when creating the L</xslate> object.  So, any
arguments which L<Text::Xslate> supports may be set.  For example:

    my $xslate = Data::Xslate->new(
        substitution_tag => ']]', # A Data::Xslate argument.
        verbose          => 2,    # A Text::Xslate option.
    );

=head2 substitution_tag

The string to look for at the beginning of any string value which
signifies L</SUBSTITUTION>.  Defaults to C<=:>.

=cut

has substitution_tag => (
    is      => 'ro',
    isa     => NonEmptySimpleStr,
    default => '=:',
);

=head1 ATTRIBUTES

=head2 xslate

The L<Text::Xslate> object used for processing template string values.

By default this will set the C<type> to C<text> and will add a C<node>
function to the C<function> (function map) option.

=cut

has xslate => (
    is       => 'lazy',
    init_arg => undef,
);
sub _build_xslate {
    my ($self) = @_;

    my $args = { %{ $self->_xslate_args() } };
    my $function = delete( $args->{function} ) || {};
    $function->{node} ||= \&_find_node_for_xslate;

    return Text::Xslate->new(
        type     => 'text',
        function => $function,
        %$args,
    );
}

=head2 vars

This is a tied hash used as the C<vars> argument to L<Text::Xslate>
allowing self-referencial lookups in templating and substitutions.

=cut

has vars => (
    is       => 'lazy',
    init_arg => undef,
);
sub _build_vars {
    my %vars;
    tie %vars, 'Data::Xslate::Vars', \&_find_node_for_xslate;
    return \%vars;
}

=head1 METHODS

=head2 render

    my $data_out = $xslate->render( $data_in );

=cut

sub render {
    my ($self, $data) = @_;

    local $Carp::Internal{ (__PACKAGE__) } = 1;

    local $XSLATE = $self->xslate();
    local $VARS = $self->vars();

    local $ROOT = $data;
    local $NODES = {};
    local $SUBSTITUTION_TAG = $self->substitution_tag();

    return _evaluate_node( 'root' => $data );
}

sub _evaluate_node {
    my ($path, $node) = @_;

    return $NODES->{$path} if exists $NODES->{$path};

    if (!ref $node) {
        if (defined $node) {
            if ($node =~ m{^$SUBSTITUTION_TAG\s*(.+?)\s*$}) {
                $node = _find_node( $1, $path );
            }
            else {
                local $PATH_FOR_XSLATE = $path;
                $node = $XSLATE->render_string( $node, $VARS );
            }
        }
        $NODES->{$path} = $node;
    }
    elsif (ref($node) eq 'HASH') {
        $NODES->{$path} = $node;
        foreach my $key (sort keys %$node) {
            my $sub_path = "$path.$key";
            if ($key =~ m{\.}) {
                my $value = delete $node->{$key};
                _set_node( $sub_path, $value );
            }
            else {
                $node->{$key} = _evaluate_node( $sub_path, $node->{$key} );
            }
        }
    }
    elsif (ref($node) eq 'ARRAY') {
        $NODES->{$path} = $node;
        @$node = (
            map { _evaluate_node( "$path.$_" => $node->[$_] ) }
            (0..$#$node)
        );
    }
    else {
        croak "The config node at $path is neither a hash, array, or scalar";
    }

    return $node;
}

sub _load_node {
    my ($path) = @_;

    my @parts = split(/\./, $path);
    my $built_path = shift( @parts ); # root

    my $node = $ROOT;
    while (@parts) {
        my $key = shift( @parts );
        $built_path .= ".$key";

        if (ref($node) eq 'HASH') {
            return undef if !exists $node->{$key};
            $node = _evaluate_node( $built_path => $node->{$key} );
        }
        elsif (ref($node) eq 'ARRAY') {
            return undef if $key > $#$node;
            $node = _evaluate_node( $built_path => $node->[$key] );
        }
        else {
            croak "The config node at $path is neither a hash or array";
        }
    }

    return $node;
}

sub _find_node {
    my ($path, $from_path) = @_;

    if ($path =~ m{^\.(.+)}) {
        $path = $1;
        $from_path = 'root.foo';
    }

    my @parts = split(/\./, $from_path);
    pop( @parts );

    while (@parts) {
        my $sub_path = join('.', @parts);

        my $node = _load_node( "$sub_path.$path" );
        return $node if $node;

        pop( @parts );
    }

    return _load_node( $path );
}

sub _find_node_for_xslate {
    my ($path) = @_;
    return _find_node( $path, $PATH_FOR_XSLATE );
}

sub _set_node {
    my ($path, $value) = @_;

    my @parts = split(/\./, $path);
    my $built_path = shift( @parts ); # root
    my $last_part = pop( @parts );

    my $node = $ROOT;
    while (@parts) {
        my $key = shift( @parts );
        $built_path .= ".$key";

        if (ref($node) eq 'HASH') {
            return 0 if !exists $node->{$key};
            $node = _evaluate_node( $built_path => $node->{$key} );
        }
        elsif (ref($node) eq 'ARRAY') {
            return 0 if $key > $#$node;
            $node = _evaluate_node( $built_path => $node->[$key] );
        }
        else {
            croak "The config node at $path is neither a hash or array";
        }
    }

    delete $NODES->{$path};
    $value = _evaluate_node( $path => $value );

    if (ref($node) eq 'HASH') {
        $node->{$last_part} = $value;
    }
    elsif (ref($node) eq 'ARRAY') {
        $node->[$last_part] = $value;
    }

    return 1;
}

1;
__END__

=head1 AUTHOR

Aran Clary Deltac <bluefeetE<64>gmail.com>

=head1 ACKNOWLEDGEMENTS

Thanks to L<ZipRecruiter|https://www.ziprecruiter.com/>
for encouraging their employees to contribute back to the open
source ecosystem.  Without their dedication to quality software
development this distribution would not exist.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

