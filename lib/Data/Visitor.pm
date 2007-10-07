#!/usr/bin/perl

package Data::Visitor;
use base qw/Class::Accessor/;

use strict;
use warnings;

use Scalar::Util qw/blessed refaddr reftype/;
use overload ();
use Symbol ();

our $VERSION = "0.08";

sub visit {
	my ( $self, $data ) = @_;

	my $seen_hash = local $self->{_seen} = ($self->{_seen} || {}); # delete it after we're done with the whole visit
	if ( ref $data ) { # only references need recursion checks
		if ( exists $seen_hash->{ refaddr( $data ) } ) { # if it's been seen
			return $seen_hash->{ refaddr( $data ) }; # return whatever it was mapped to
		} else {
			my $seen = \( $seen_hash->{ refaddr( $data ) } );
			$$seen = $data;

			if ( defined wantarray ) {
				return $$seen = $self->visit_no_rec_check( $data );
			} else {
				return $self->visit_no_rec_check( $data );
			}
		}
	} else {
		return $self->visit_no_rec_check( $data );
	}
}

sub visit_no_rec_check {
	my ( $self, $data ) = @_;

	if ( blessed( $data ) ) {
		return $self->visit_object( $data );
	} elsif ( ref $data ) {
		return $self->visit_ref( $data );
	}
	
	return $self->visit_value( $data );
}

sub visit_object {
	my ( $self, $object ) = @_;

	return $self->visit_value( $object );
}

sub visit_ref {
	my ( $self, $data ) = @_;

	 my $reftype = reftype $data;

	my $method = lc "visit_$reftype";

	if ( $self->can($method) ) {
		return $self->$method( $data );
	} else {
		return $self->visit_value($data);
	}

}

sub visit_value {
	my ( $self, $value ) = @_;

	return $value;
}

sub visit_hash {
	my ( $self, $hash ) = @_;

	if ( not defined wantarray ) {
		foreach my $key ( keys %$hash ) {
			$self->visit_hash_entry( $key, $hash->{$key}, $hash );
		}
	} else {
		return $self->retain_magic( $hash, { map { $self->visit_hash_entry( $_, $hash->{$_}, $hash ) } keys %$hash } );
	}
}

sub visit_hash_entry {
	my ( $self, $key, $value, $hash ) = @_;

	return (
		$self->visit_hash_key($key,$value,$hash),
		$self->visit_hash_value($_[2],$key,$hash) # retain aliasing semantics
	);
}

sub visit_hash_key {
	my ( $self, $key, $value, $hash ) = @_;
	$self->visit($key);
}

sub visit_hash_value {
	my ( $self, $value, $key, $hash ) = @_;
	$self->visit($_[1]); # retain it's aliasing semantics
}

sub visit_array {
	my ( $self, $array ) = @_;

	if ( not defined wantarray ) {
		$self->visit_array_entry( $array->[$_], $_, $array ) for 0 .. $#$array
	} else {
		return $self->retain_magic( $array, [ map { $self->visit_array_entry( $array->[$_], $_, $array ) } 0 .. $#$array ] );
	}
}

sub visit_array_entry {
	my ( $self, $value, $index, $array ) = @_;
	$self->visit($_[1]);
}

sub visit_scalar {
	my ( $self, $scalar ) = @_;
	return $self->retain_magic( $scalar, \$self->visit( $$scalar ) );
}

sub visit_glob {
	my ( $self, $glob ) = @_;

	my $new_glob = Symbol::gensym();

	no warnings 'misc'; # Undefined value assigned to typeglob
	*$new_glob = $self->visit( *$glob{$_} || next ) for qw/SCALAR ARRAY HASH/;

	return $self->retain_magic( $glob, $new_glob );
}

sub retain_magic {
	my ( $self, $proto, $new ) = @_;

	if ( blessed($proto) and !blessed($new) ) {
		bless $new, ref $proto;
	}

	# FIXME real magic, too

	return $new;
}

__PACKAGE__;

__END__

=pod

=head1 NAME

Data::Visitor - Visitor style traversal of Perl data structures

=head1 SYNOPSIS

	# NOTE
	# You probably want to use Data::Visitor::Callback for trivial things

	package FooCounter;
	use base qw/Data::Visitor/;

	BEGIN { __PACKAGE__->mk_accessors( "number_of_foos" ) };

	sub visit_value {
		my ( $self, $data ) = @_;

		if ( defined $data and $data eq "foo" ) {
			$self->number_of_foos( ($self->number_of_foos || 0) + 1 );
		}

		return $data;
	}

	my $counter = FooCounter->new;

	$counter->visit( {
		this => "that",
		some_foos => [ qw/foo foo bar foo/ ],
		the_other => "foo",
	});

	$counter->number_of_foos; # this is now 4

=head1 DESCRIPTION

This module is a simple visitor implementation for Perl values.

It has a main dispatcher method, C<visit>, which takes a single perl value and
then calls the methods appropriate for that value.

=head1 METHODS

=over 4

=item visit $data

This method takes any Perl value as it's only argument, and dispatches to the
various other visiting methods, based on the data's type.

=item visit_object $object

If the value is a blessed object, C<visit> calls this method. The base
implementation will just forward to C<visit_value>.

=item visit_ref $value

Generic recursive visitor. All non blessed values are given to this.

C<visit_object> can delegate to this method in order to visit the object
anyway.

This will check if the visitor can handle C<visit_$reftype> (lowercase), and if
not delegate to C<visit_value> instead.

=item visit_array $array_ref

=item visit_hash $hash_ref

=item visit_glob $glob_ref

=item visit_scalar $scalar_ref

These methods are called for the corresponding container type.

=item visit_value $value

If the value is anything else, this method is called. The base implementation
will return $value.

=item visit_hash_entry $key, $value, $hash

Delegates to C<visit_hash_key> and C<visit_hash_value>. The value is passed as
C<$_[2]> so that it is aliased.

=item visit_hash_key $key, $value, $hash

Calls C<visit> on the key and returns it.

=item visit_hash_value $value, $key, $hash

The value will be aliased (passed as C<$_[1]>).

=item visit_array_entry $value, $index, $array

Delegates to C<visit> on value. The value is passed as C<$_[1]> to retain
aliasing.

=back

=head1 RETURN VALUE

This object can be used as an C<fmap> of sorts - providing an ad-hoc functor
interface for Perl data structures.

In void context this functionality is ignored, but in any other context the
default methods will all try to return a value of similar structure, with it's
children also fmapped.

=head1 SUBCLASSING

Create instance data using the L<Class::Accessor> interface. L<Data::Visitor>
inherits L<Class::Accessor> to get a sane C<new>.

Then override the callback methods in any way you like. To retain visitor
behavior, make sure to retain the functionality of C<visit_array> and
C<visit_hash>.

=head1 TODO

=over 4

=item *

Add support for "natural" visiting of trees.

=item *

Expand C<retain_magic> to support tying at the very least, or even more with
L<Variable::Magic> if possible.

Tied values might be redirected to an alternate handler that builds a new empty
value, and ties it to a visited clone of the object the original is tied to
using a trampoline class. Look into this.

=back

=head1 SEE ALSO

L<Tree::Simple::VisitorFactory>, L<Data::Traverse>

L<http://en.wikipedia.org/wiki/Visitor_pattern>,
L<http://www.ninebynine.org/Software/Learning-Haskell-Notes.html#functors>,
L<http://en.wikipedia.org/wiki/Functor>

=head1 AUTHOR

Yuval Kogman <nothingmuch@woobling.org>

=head1 COPYRIGHT & LICENSE

	Copyright (c) 2006 Yuval Kogman. All rights reserved
	This program is free software; you can redistribute
	it and/or modify it under the same terms as Perl itself.

=cut


