package Rose::DBx::Object::Cached::CHI;

use strict;

use Carp();

use CHI;
use Storable;
use Rose::DB::Object;
use Rose::DB::Object::Helpers;
use Data::Dumper;
our @ISA = qw(Rose::DB::Object);

use Rose::DB::Object::Constants qw(STATE_IN_DB);

#$Storable::forgive_me = 1;
#$Storable::Deparse = 1;
#$Storable::Eval = 1;

our $VERSION = '0.03';
our $SETTINGS = {
        driver=>'Memory',
    };

our $Debug = 0;

# Anything that cannot be in a column name will work for these
use constant PK_SEP => "\0\0";
use constant UK_SEP => "\0\0";
use constant LEVEL_SEP => "\0\0";

# Try to pick a very unlikely value to stand in for undef in
# the stringified multi-column unique key value
use constant UNDEF  => "\1\2undef\2\1";

sub remember
{
  my($self) = shift;
  my $class = ref $self;
  my $cache = $class->__xrdbopriv_get_cache_handle;

  my $pk = join(PK_SEP, grep { defined } map { $self->$_() } $self->meta->primary_key_column_names);

  $cache->set("${class}::Objects_By_Id" . LEVEL_SEP . $pk, $self->clone->strip,($self->cached_objects_expire_in || $SETTINGS->{expire_in} || 'never'));


  foreach my $cols ($self->meta->unique_keys_column_names)
  {
    my $key_name  = join(UK_SEP, @$cols);
    my $key_value = join(UK_SEP, grep { defined($_) ? $_ : UNDEF }
                         map { $self->$_() } @$cols);

    $cache->set("${class}::Objects_By_Key" . LEVEL_SEP . $key_name . LEVEL_SEP . $key_value, $self->clone->strip, ($self->cached_objects_expire_in || $SETTINGS->{expire_in} || 'never'));
    $cache->set("${class}::Objects_Keys" . LEVEL_SEP . $pk . LEVEL_SEP . $key_name, $key_value, ($self->cached_objects_expire_in || $SETTINGS->{expire_in} || 'never'));

  }

  $self->{__xrdbopriv_chi_created_at} = $cache->get_object("${class}::Objects_By_Id" . LEVEL_SEP . $pk)->created_at();

};

# This constant is not arbitrary.  It must be defined and false.
# I'm playing games with return values, but this is all internal
# anyway and can change at any time.

sub __xrdbopriv_get_object
{
  my($class) = ref $_[0] || $_[0];

  my $cache = $class->__xrdbopriv_get_cache_handle;

  if(@_ == 2)
  {
    my($pk) = $_[1];

    my $object = $cache->get("${class}::Objects_By_Id" . LEVEL_SEP . $pk);
    if($object)
    {
      $object->{__xrdbopriv_chi_created_at} = $cache->get_object("${class}::Objects_By_Id" . LEVEL_SEP . $pk)->created_at;
      return $object;
    }

    return undef;
  }
  else
  {
    my($key_name, $key_value) = ($_[1], $_[2]);

    my $object = $cache->get("${class}::Objects_By_Key" . LEVEL_SEP . $key_name . LEVEL_SEP . $key_value);
    if($object)
    {
      #$object->remember();
      $object->{__xrdbopriv_chi_created_at} = $cache->get_object("${class}::Objects_By_Key" . LEVEL_SEP . $key_name . LEVEL_SEP . $key_value)->created_at;
      return $object;
    }

    return undef;
  }
};

sub load
{
  # XXX: Must maintain alias to actual "self" object arg

  my %args = (self => @_); # faster than @_[1 .. $#_];

  my $class = ref $_[0];

  unless(delete $args{'refresh'})
  {
    my $pk = join(PK_SEP, grep { defined } map { $_[0]->$_() } $_[0]->meta->primary_key_column_names);

    my $object = $pk ? __xrdbopriv_get_object($class, $pk) : undef;

    if($object)
    {
      $_[0] = $object;
      $_[0]->{STATE_IN_DB()} = 1;
      return $_[0] || 1;
    }
    elsif(!(defined $object))
    {
      foreach my $cols ($_[0]->meta->unique_keys_column_names)
      {
        no warnings;
        my $key_name  = join(UK_SEP, @$cols);
        my $key_value = join(UK_SEP, grep { defined($_) ? $_ : UNDEF }
                             map { $_[0]->$_() } @$cols);

        if(my $object = __xrdbopriv_get_object($class, $key_name, $key_value))
        {
          $_[0] = $object;
          $_[0]->{STATE_IN_DB()} = 1;
          return $_[0] || 1;
        }
      }
    }
  }

  my $ret = $_[0]->SUPER::load(%args);
  $_[0]->remember  if($ret);

  return $ret;
}

sub save
{
  my($self) = shift;

  my $ret = $self->SUPER::save(@_);
  return $ret  unless($ret);

  $self->remember;

  return $ret;
}

sub delete
{
  my($self) = shift;
  my $ret = $self->SUPER::delete(@_);
  $self->forget  if($ret);
  return $ret;
}

sub forget
{
  my($self) = shift;
  my $class = ref $self;

  my $cache = $class->__xrdbopriv_get_cache_handle;

  my $pk = join(PK_SEP, grep { defined } map { $self->$_() } $self->meta->primary_key_column_names);

  $cache->expire("${class}::Objects_By_Id" . LEVEL_SEP . $pk);

  foreach my $cols ($self->meta->unique_keys_column_names)
  {
    my $key_name  = join(UK_SEP, @$cols);
    my $key_value = $cache->get("${class}::Objects_Keys" . LEVEL_SEP . $pk . LEVEL_SEP . $key_name) || '';
    $cache->expire("${class}::Objects_By_Key" . LEVEL_SEP . $key_name . LEVEL_SEP . $key_value);
  }

  $cache->expire("${class}::Objects_Keys" . LEVEL_SEP . $pk);

  return 1;
}

sub remember_by_primary_key
{
  my($self) = shift;
  my $class = ref $self;

  my $cache = $class->__xrdbopriv_get_cache_handle;

  my $pk = join(PK_SEP, grep { defined } map { $self->$_() } $self->meta->primary_key_column_names);

  $cache->set("${class}::Objects_By_Id" . LEVEL_SEP . $pk, $self->clone->strip);
}

sub remember_all
{
  my($class) = shift;

  require Rose::DB::Object::Manager;

  my(undef, %args) = Rose::DB::Object::Manager->normalize_get_objects_args(@_);

  my $objects =
    Rose::DB::Object::Manager->get_objects(
      object_class => $class,
      share_db     => 0,
      %args);

  foreach my $object (@$objects)
  {
    $object->remember;
  }

  return @$objects  if(defined wantarray);
}

# Code borrowed from Cache::Cache
my %Expiration_Units =
(
  map(($_,            1), qw(s sec secs second seconds)),
  map(($_,           60), qw(m min mins minute minutes)),
  map(($_,        60*60), qw(h hr hrs hour hours)),
  map(($_,     60*60*24), qw(d day days)),
  map(($_,   60*60*24*7), qw(w wk wks week weeks)),
  map(($_, 60*60*24*365), qw(y yr yrs year years))
);

sub clear_object_cache
{
  my($class) = shift;

  my $cache = $class->__xrdbopriv_get_cache_handle;

  $cache->clear;
}


sub cached_objects_expire_in
{
  my($class) = shift;

  no strict 'refs';
  return ${"${class}::Cache_Expires"} ||= 0  unless(@_);

  my $arg = shift;

  my $secs;

  if($arg =~ /^now$/i)
  {
    $class->forget_all;
    $secs = 0;
  }
  elsif($arg =~ /^never$/)
  {
    $secs = 0;
  }
  elsif($arg =~ /^\s*([+-]?(?:\d+|\d*\.\d*))\s*$/)
  {
    $secs = $arg;
  }
  elsif($arg =~ /^\s*([+-]?(?:\d+(?:\.\d*)?|\d*\.\d+))\s*(\w*)\s*$/ && exists $Expiration_Units{$2})
  {
    $secs = $Expiration_Units{$2} * $1;
  }
  else
  {
    Carp::croak("Invalid cache expiration time: '$arg'");
  }

  return ${"${class}::Cache_Expires"} = $secs;
}

sub cached_objects_settings {
    my ($class, %params) = @_;;

    no strict 'refs';

    if (keys %params) {

        ${"${class}::CHI_SETTINGS"} = \%params;

    } else {
        if (defined ${"${class}::CHI_SETTINGS"}) {
            return ${"${class}::CHI_SETTINGS"};
        } else {
            ${"${class}::CHI_SETTINGS"} = $SETTINGS;
        }
    }

}


sub is_cache_in_sync {
    my $self = shift;

    my $class = ref $self;
    my $cache = $class->__xrdbopriv_get_cache_handle;
    my $pk = join(PK_SEP, grep { defined } map { $self->$_() } $self->meta->primary_key_column_names);
    my $created_at = $cache->get_object("${class}::Objects_By_Id" . LEVEL_SEP . $pk)->created_at;

    if ($created_at) {
        return ($self->{__xrdbopriv_chi_created_at} == $created_at);
    } else {
        if ($_[0]->{STATE_IN_DB()}) {
          # Has been loaded
	} else {
          Carp::cluck "Object never loaded";
	}
	return 0;
    }

}


sub __xrdbopriv_get_cache_handle {
    my $class = shift;

    no strict 'refs';

    if (defined ${"${class}::CHI_CACHE_HANDLE"}) {
        return ${"${class}::CHI_CACHE_HANDLE"};
    } else {
        my %defaults = (
            driver=>'Memory',
            namespace=>$class,
        );

        my $current_settings = $class->cached_objects_settings;

        my %chi_settings = (%defaults, %{$current_settings});

        my $cache = new CHI(%chi_settings);

        ${"${class}::CHI_CACHE_HANDLE"} = $cache;
        return $cache;
    }
}


sub strip {
    my $self = shift;

    Rose::DB::Object::Helpers::strip($self,@_);

    delete $self->{__xrdbopriv_chi_created_at};

    return $self;
}

sub clone {
    my $self = shift;

    Rose::DB::Object::Helpers::clone($self,@_);
}




1;

__END__


=head1 NAME

Rose::DBx::Object::Cached::CHI - Rose::DB::Object Cache using the CHI interface

=head1 SYNOPSIS

  package Category;

  use Rose::DBx::Object::Cached::CHI;
  our @ISA = qw(Rose::DBx::Object::Cached::CHI);

  __PACKAGE__->meta->table('categories');

  __PACKAGE__->meta->columns
  (
    id          => { type => 'int', primary_key => 1 },
    name        => { type => 'varchar', length => 255 },
    description => { type => 'text' },
  );

  __PACKAGE__->meta->add_unique_key('name');

  __PACKAGE__->meta->initialize;

  ...

  ## Defaults to an in memory cache that does not expire.

  $cat1 = Category->new(id   => 123,
                        name => 'Art');

  $cat1->save or die $category->error;


  $cat2 = Category->new(id => 123);

  # This will load from the memory cache, not the database
  $cat2->load or die $cat2->error; 

  ...

  ## Set the cache driver for all Rose::DB::Object derived objects
  $Rose::DBx::Object::Cached::CHI::SETTINGS = {
    driver     => 'FastMmap',
    root_dir   => '/tmp/global_fastmmap',
  };

  $cat1 = Category->new(id   => 123,
                        name => 'Art')->save;

  ## In another script

  $Rose::DBx::Object::Cached::CHI::SETTINGS = {
    driver     => 'FastMmap',
    root_dir   => '/tmp/global_fastmmap',
  };

  # This will load from the FastMmap cache, not the database
  $cat2 = Category->new(id   => 123,
                        name => 'Art')->load;

  ...

  ## Set the cache driver for all Category derived objects
  Category->cached_objects_settings(
    driver     => 'FastMmap',
    root_dir   => '/tmp/global_fastmmap',
  );

  ...


  ## Set cache expire time for all Category objects
  Category->cached_objects_expire_in('5 seconds'); 

  ## Set cache expire time for all Rose::DB::Object derived objects
  $Rose::DBx::Object::Cached::CHI::SETTINGS = {
    driver     => 'Memory',
    expires_in    => '15 minutes',
  };

  <OR> 

  $Rose::DBx::Object::Cached::CHI::SETTINGS = {
    driver     => 'FastMmap',
    root_dir   => '/tmp/global_fastmmap',
    expires_in    => '15 minutes',
  };

  ## Any driver for CHI will work.
  


=head1 DESCRIPTION

This module intends to extend the caching ability in Rose::DB::Object 
allowing objects to be cached by any driver that can be used with 
the CHI interface. This opens the possibility to cache objects across 
scripts or even servers by opening up methods of caching such as 
FastMmap and memcached.

Most of the code is taken straight from L<Rose::DB::Object::Cached>.
This does not extend Rose::DB::Object::Cached because function calls and
how the cache is accessed needed to be changed thoughout the code.

=head1 MAJOR DIFFERENCE from L<Rose::DB::Object::Cached>

All objects derived from a L<Rose::DBx::Object::Cached> class are 
set and retrieved from CHI, therefore 2 objects that are
loaded with the same parameters are not the same code reference.

=over 4

=item B<In L<Rose::DB::Object::Cached>>

=over 4

  $cat1 = Category->new(id   => 123,
                          name => 'Art');

  $cat1->save;

  $cat2-> Category->new(id   => 123,
                          name => 'Art');
     
  $cat2->load;

  print $cat1->name; # prints "Art"

  print $cat2->name; # prints "Art"

  $cat1->name('Blah');

  print $cat2->name; # prints "Blah"

=back

=item  B<In L<Rose::DBx::Object::Cached>>

=over 4
    
  $cat1 = Category->new(id   => 123,
                          name => 'Art');

  $cat1->save;

  $cat2-> Category->new(id   => 123,
                          name => 'Art');

  $cat2->load;

  print $cat1->name; # prints "Art"
  print $cat2->name; # prints "Art"

  $cat1->name('Blah');
  print $cat2->name; # prints "Art"

=back
 

=back

=head1 GLOBALS

=over 4

=item B<$SETTINGS>

This global is used to set CHI settings for all objects derived from L<Rose::DBx::Object::Cached>.
Any settings here will be conceded to settings configured by the class method L<cached_object_settings|/cached_object_settings>

=over 4

Example:

$Rose::DBx::Object::Cached::CHI::SETTINGS = {
    driver     => 'FastMmap',
    root_dir   => '/tmp/global_fastmmap',
};


=back


=back



=head1 CLASS METHODS

Only class methods that do not exist in L<Rose::DB::Object::Cached> are listed here.

=over 4

=item B<cached_object_settings [PARAMS]>

If called with no arguments this will return the current cache settings.  PARAMS are any valid options for the L<CHI> constructor.

    Example:

    Category->cached_objects_settings (
        driver     => 'FastMmap',
        root_dir   => '/tmp/global_fastmmap',
        expires_in    => '15 minutes',
    )


=back


=head1 OBJECT METHODS

Only object methods that do not exist in L<Rose::DB::Object::Cached> are listed here.

=over 4

=item B<is_cache_in_sync>

Because the cache is only updated when loading and saving this method will return weather the cache has been updated since the object was last loaded.

Returns true if the object is in sync with what exists in the cache.  Returns false if the cache has been updated since the object was loaded.

=item B<clone>

Calls the L<clone|Rose::DB::Object::Helpers/clone> method in L<Rose::DB::Object::Helpers>

=over 4

Because of the nature of L<Storable> all objects set to cache are set by $object->clone->strip

=back

=item B<strip>

Calls the L<strip|Rose::DB::Object::Helpers/strip> method in L<Rose::DB::Object::Helpers>

=over 4

Because of the nature of L<Storable> all objects set to cache are set by $object->clone->strip

=back



=back


=head1 TODO

=over 4

=item B<Tests>

Currently tests only exist for MySQL.  Almost all of these have been copied directly from the tests that exist for L<Rose::DB::Object>.

=back



=head1 SUPPORT

Right now you can email kmcgrath@baknet.com.

=head1 AUTHOR

    Kevin C. McGrath
    CPAN ID: KMCGRATH
    kmcgrath@baknet.com

=head1 COPYRIGHT

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.


=head1 SEE ALSO

perl(1).

=cut

#################### main pod documentation end ###################


