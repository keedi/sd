package App::SD::ForeignReplica;

# ABSTRACT: Base class for foreign replicas

use Any::Moose;
use Params::Validate qw/:all/;

use Try::Tiny;
use URI;

extends 'Prophet::ForeignReplica';

has uuid => (
    lazy    => 1,
    isa     => 'Str',
    is      => 'ro',
    default => sub {
        my $self = shift;
        $self->uuid_for_url( $self->_uuid_url );
    }
);

=method save_username_and_token( $username, $token )

Saves the given username and token to the replica-specific config file, so the
user doesn't have to enter it every time.

=cut

sub save_username_and_token {
    my ( $self, $username, $password ) = @_;

    # make sure replica is initialized, since this method is generally called
    # in the BUILD method of an object, which makes it end up being called
    # before the initialize call in clone
    $self->app_handle->handle->after_initialize(
        sub { shift->app_handle->set_db_defaults } );
    $self->app_handle->handle->initialize;

    my $replica_username_key = 'replica.' . $self->{url} . '.username';
    my $replica_token_key    = 'replica.' . $self->{url} . '.secret_token';

    if ( !$self->app_handle->config->get( key => $replica_username_key ) ) {
        print "Setting replica's username and token in the config file";
        $self->app_handle->config->group_set(
            $self->app_handle->config->replica_config_file,
            [
                {
                    key   => $replica_username_key,
                    value => $username,
                },
                {
                    key   => $replica_token_key,
                    value => $password,
                }
            ],
        );
    }
}

sub integrate_changeset {
    my $self = shift;
    my %args = validate(
        @_,
        {
            changeset          => { isa      => 'Prophet::ChangeSet' },
            resolver           => { optional => 1 },
            resolver_class     => { optional => 1 },
            resdb              => { optional => 1 },
            conflict_callback  => { optional => 1 },
            reporting_callback => { optional => 1 }
        }
    );

    my $changeset = $args{'changeset'};
    return
      if $self->last_changeset_from_source( $changeset->original_source_uuid )
      >= $changeset->original_sequence_no;
    $self->SUPER::integrate_changeset(%args);
}

=method integrate_change( $change, $changeset )

Given a change (and the changeset it's part of), this routine will load the
push encoder for the foreign replica's type and call integrate_change on it.

To avoid publishing prophet-private data, It skips any change with a record
type that record_type starts with '__'.

This is probably a bug.

=cut

sub integrate_change {
    my $self = shift;
    my ( $change, $changeset ) = validate_pos(
        @_,
        { isa => 'Prophet::Change' },
        { isa => 'Prophet::ChangeSet' },
    );

    # don't push internal records
    return if $change->record_type =~ /^__/;

    Prophet::App->require( $self->push_encoder() );
    my $recoder = $self->push_encoder->new( { sync_source => $self } );
    $recoder->integrate_change( $change, $changeset );
}

=method record_pushed_transactions( $ticket, $changeset, $start_time) 

Walk the set of transactions on the ticket whose id you've passed in, looking
for updates by the 'current user' which happened after start_time and before
now. Then mark those transactions as ones that originated in SD, so we don't
accidentally push them later.

=cut

sub record_pushed_transactions {
    my $self = shift;
    my %args = validate(
        @_,
        {
            ticket     => 1,
            changeset  => { isa => 'Prophet::ChangeSet' },
            start_time => 1
        }
    );

    my $earliest_valid_txn_date;

    # walk through every transaction on the ticket, starting with the latest

    for my $txn ( $self->get_txn_list_by_date( $args{ticket} ) ) {

        # walk backwards through all transactions on the ticket we just updated
        # Skip any transaction where the remote user isn't me, this might
        # include any transaction RT created with a scrip on your behalf

        next unless $txn->{creator} eq $self->foreign_username;

        # get the completion time _after_ we do our next round trip to rt to
        # try to make sure a bit of lag doesn't skew us to the wrong side of a
        # 1s boundary
        if ( !$earliest_valid_txn_date ) {
            my $change_window = time() - $args{start_time};

            # skip any transaction created more than 5 seconds before the push
            # started. I can't think of any reason that number shouldn't be 1,
            # but clocks are fickle
            $earliest_valid_txn_date =
              $txn->{created} - ( $change_window + 5 );
        }

        last if $txn->{created} < $earliest_valid_txn_date;

        # if the transaction id is older than the id of the last changeset
        # we got from the original source of this changeset, we're done
        last
          if $txn->{id} <=
          $self->app_handle->handle->last_changeset_from_source(
            $args{changeset}->original_source_uuid );

        # if the transaction from RT is more recent than the most recent
        # transaction we got from the original source of the changeset
        # then we should record that we sent that transaction upstream

        $self->record_pushed_transaction(
            transaction => $txn->{id},
            changeset   => $args{'changeset'},
            record      => $args{'ticket'}
        );
    }
}

=method record_pushed_transaction( $foreign_transaction_id, $changeset )

Record that this replica was the original source of $foreign_transaction_id
(with changeset $changeset)

=cut

sub record_pushed_transaction {
    my $self = shift;
    my %args = validate(
        @_,
        {
            transaction => 1,
            changeset   => { isa => 'Prophet::ChangeSet' },
            record      => 1
        }
    );

    my $key = join( '-',
        "foreign-txn-from", $self->uuid,
        'record', $args{record}, 'txn', $args{transaction} );
    my $value = join( ':',
        $args{changeset}->original_source_uuid,
        $args{changeset}->original_sequence_no );

    $self->store_local_metadata( $key => $value );

}

=method foreign_transaction_originated_locally( $transaction_id, $foreign_record_id )

Given a transaction id, will return true if this transaction originated in
Prophet and was pushed to the foreign replica or originated in the foreign
replica and has already been pulled to the Prophet replica.


This is a mapping of all the transactions we have pushed to the remote replica
we'll only ever care about remote sequence #s greater than the last transaction
# we've pulled from the remote replica once we've done a pull from the remote
replica, we can safely expire all records of this type for the remote replica
(they'll be obsolete)

We use this cache to avoid integrating changesets we've pushed to the remote
replica when doing a subsequent pull

=cut

sub foreign_transaction_originated_locally {
    my $self = shift;
    my ( $id, $record ) = validate_pos( @_, 1, 1 );
    return $self->fetch_local_metadata( "foreign-txn-from-"
          . $self->uuid
          . '-record-'
          . $record . '-txn-'
          . $id );
}

sub traverse_changesets {
    my $self = shift;
    my %args = validate(
        @_,
        {
            after    => 1,
            callback => 1,
            before_load_changeset_callback =>
              { type => CODEREF, optional => 1 },
            reporting_callback => { type => CODEREF, optional => 1 },
        }
    );

    Prophet::App->require( $self->pull_encoder() );
    my $recoder = $self->pull_encoder->new( { sync_source => $self } );
    my ($changesets) = $recoder->run( after => $args{'after'} );
    for my $changeset (@$changesets) {
        if ( $args{'before_load_changeset_callback'} ) {
            my $continue =
              $args{'before_load_changeset_callback'}->( changeset_metadata =>
                  $self->_construct_changeset_index_entry($changeset) );

            next unless $continue;
        }

        $args{callback}->(
            changeset                 => $changeset,
            after_integrate_changeset => sub {
                $self->record_last_changeset_from_replica(
                    $changeset->original_source_uuid =>
                      $changeset->original_sequence_no );

                # We're treating each individual ticket in the foreign system
                # as its own 'replica' because of that, we need to hint to the
                # push side of the system what the most recent txn on each
                # ticket it has.
                my $previously_modified = App::SD::Util::string_to_datetime(
                    $self->upstream_last_modified_date || '' );
                my $created_datetime =
                  App::SD::Util::string_to_datetime( $changeset->created );
                $self->record_upstream_last_modified_date(
                    $changeset->created )
                  if ( ( $created_datetime ? $created_datetime->epoch : 0 ) >
                    ( $previously_modified ? $previously_modified->epoch : 0 )
                  );
            }
        );
        $args{reporting_callback}->($changeset)
          if ( $args{reporting_callback} );
    }
}

sub _construct_changeset_index_entry {
    my $self      = shift;
    my $changeset = shift;

    return [
        $changeset->sequence_no,          $changeset->original_source_uuid,
        $changeset->original_sequence_no, $changeset->calculate_sha1
    ];
}

sub remote_uri_path_for_id {
    die "your subclass needs to implement this to be able to "
      . "map a remote id to /ticket/id or soemthing";
}

=method uuid_for_remote_id( $id )

lookup the uuid for the remote record id. If we don't find it, construct it out
of the remote url and the remote uri path for the record id;

=cut

sub uuid_for_remote_id {
    my ( $self, $id ) = @_;

    return $self->_lookup_uuid_for_remote_id($id)
      || $self->_url_based_uuid_for_remote_ticket_id($id);
}

sub _lookup_uuid_for_remote_id {
    my $self = shift;
    my ($id) = validate_pos( @_, 1 );

    return $self->fetch_local_metadata(
        'local_uuid_for_' . $self->_url_based_uuid_for_remote_ticket_id($id) );
}

sub _set_uuid_for_remote_id {
    my $self = shift;
    my %args = validate( @_, { uuid => 1, remote_id => 1 } );
    return $self->store_local_metadata(
        'local_uuid_for_'
          . $self->_url_based_uuid_for_remote_ticket_id( $args{'remote_id'} ),
        $args{uuid}
    );
}

sub _url_based_uuid_for_remote_ticket_id {
    my $self = shift;
    my $id   = shift;

    return $self->uuid_for_url(
        $self->remote_url . $self->remote_uri_path_for_id($id) );
}

# This mapping table stores uuids for tickets we've synced from a remote
# database Basically, if we created the ticket to begin with, then we'll know
# its uuid if we pulled the ticket from the foreign replica then its uuid will
# be generated based on a UUID-from-ticket-url scheme

sub remote_id_for_uuid {
    my ( $self, $uuid_or_luid ) = @_;

    require App::SD::Model::Ticket;
    my $ticket = App::SD::Model::Ticket->new(
        app_handle => $self->app_handle,
        type       => 'ticket'
    );
    $ticket->load( $uuid_or_luid =~ /^\d+$/ ? 'luid' : 'uuid', $uuid_or_luid )
      or do {
        warn "couldn't load ticket #$uuid_or_luid";
        return;
      };

    my $prop = $self->uuid . '-id';
    my $id   = $ticket->prop($prop)
      or warn "ticket #$uuid_or_luid has no property '$prop'";
    return $id;
}

sub _set_remote_id_for_uuid {
    my $self = shift;
    my %args = validate(
        @_,
        {
            uuid      => 1,
            remote_id => 1
        }
    );

    require App::SD::Model::Ticket;
    my $ticket = App::SD::Model::Ticket->new(
        app_handle => $self->app_handle,
        type       => 'ticket'
    );
    $ticket->load( uuid => $args{'uuid'} );
    $ticket->set_props(
        props => { $self->uuid . '-id' => $args{'remote_id'} } );
}

=method record_remote_id_for_pushed_record

When pushing a record created within the prophet cloud to a foreign replica, we
need to do bookkeeping to record the prophet uuid to remote id mapping.

=cut

sub record_remote_id_for_pushed_record {
    my $self = shift;
    my %args = validate(
        @_,
        {
            uuid      => 1,
            remote_id => 1
        }
    );
    $self->_set_uuid_for_remote_id(%args);
    $self->_set_remote_id_for_uuid(%args);
}

sub record_upstream_last_modified_date {
    my $self = shift;
    my $date = shift;
    return $self->store_local_metadata( 'last_modified_date' => $date );
}

sub upstream_last_modified_date {
    my $self = shift;
    return $self->fetch_local_metadata('last_modified_date');
}

=method login_loop

Loop on prompting for username/password until login is successful; user can
abort with ^C.

Saves username and password to the replica's configuration file upon successful
login.

=for :list
* uri        
login url
* username
optional; a pre-seeded username
* password
optional; a pre-seeded password
* username_prompt
optional; custom username prompt
* secret_prompt  
optional; custom secret prompt
* login_callback
coderef of code that attempts login;
should throw exception on error
* oauth_callback  
coderef of code that returns an oauth token;
should throw exception on error
* catch_callback
optional; process thrown exception message (e.g. munge 
in some way and then print to STDERR)

returns: ($username, $password)

=cut

sub login_loop {
    my $self = shift;
    my %args = @_;

    my $login_successful = 0;
    my ( $username, $password );

    my %login_args = ( uri => $args{uri}, username => $username );
    $login_args{username_prompt} = $args{username_prompt}
      if $args{username_prompt};
    $login_args{secret_prompt} = $args{secret_prompt}
      if $args{secret_prompt};

    # allow prompting for just password if username already specified
    # and vice-versa for password
    # if both are specified, we still want to loop in case the
    # credentials are wrong
    $login_args{username} = $args{username} if $args{username};
    $login_args{password} = $args{password} if $args{password};

    while ( !$login_successful ) {
        ( $username, $password ) = $self->prompt_for_login(%login_args);

        try {
            $args{login_callback}->( $self, $username, $password );
            $login_successful = 1;
        }
        catch {
            if ( $args{catch_callback} ) {
                $args{catch_callback}->($_);
            } else {
                warn "\n$_\n\n";
            }

            # in the case of a failed login, reset username/password
            # to nothing so we re-prompt for both in the case of
            # having used saved values
            ( $login_args{username}, $login_args{password} ) =
              ( undef, undef );
        };

        if ( $args{oauth_callback} ) {
            try {
                $password = $args{oauth_callback}->($self);
            }
            catch {
                if ( $args{catch_callback} ) {
                    $args{catch_callback}->($_);
                } else {
                    warn "\n$_\n\n";
                }
            };
        }
        $self->foreign_username($username) if ($username);
    }

    # only save username/password/token if login was successful
    $self->save_username_and_token( $username, $password );

    return ( $username, $password );
}

=method extract_auth_from_uri( $uri_string )

Given a server URI string, possibly containing auth info, extract the auth info
if it exists.

Also sets the remote_url and url attribute to the server URI with the auth
information removed.

returns: ($username, $password)

=cut

sub extract_auth_from_uri {
    my ( $self, $uri_string ) = @_;

    my $uri = URI->new($uri_string);
    my ( $username, $password );

    if ( $uri->can('userinfo') && ( my $auth = $uri->userinfo ) ) {
        ( $username, $password ) = split /:/, $auth, 2;
        $uri->userinfo(undef);
    }
    $self->remote_url("$uri");
    $self->url("$uri");

    return ( $username, $password );
}

sub foreign_username {
    die "replica class must implement foreign_username";
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;
