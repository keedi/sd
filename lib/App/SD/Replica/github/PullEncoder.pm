package App::SD::Replica::github::PullEncoder;
use Any::Moose;
extends 'App::SD::ForeignReplica::PullEncoder';

use Params::Validate qw(:all);
use Memoize;
use DateTime;

use App::SD::Util;

has sync_source => (
    isa => 'App::SD::Replica::github',
    is  => 'rw',
);

my %PROP_MAP = %App::SD::Replica::github::PROP_MAP;

sub ticket_id {
    my $self   = shift;
    return shift->{number};
}

=head2 translate_ticket_state

=cut

sub translate_ticket_state {
    my $self   = shift;
    my $ticket = shift;

    $ticket->{created_at} =
        App::SD::Util::string_to_datetime($ticket->{created_at});
    $ticket->{updated_at} =
        App::SD::Util::string_to_datetime($ticket->{updated_at});

    $ticket->{creator}   = $self->resolve_user_id_to( email_address => $ticket->{user}->{login} );
    $ticket->{reporter}  = $ticket->{creator}; # no difference in github...?
    
    if ($ticket->{assignee}) {
        $ticket->{owner}      = $self->resolve_user_id_to( email_address => $ticket->{assignee}->{login} );
    }
    
    $ticket->{milestone}   = $ticket->{milestone}->{title};
    $ticket->{description} =  $ticket->{body};
    
    # TODO check labels names to see if they match sd components
    $ticket->{tags} = join ', ', map { $_->{name} } @{ $ticket->{labels} };
    
    return $ticket;
}

=head2 find_matching_tickets QUERY

Returns a array of all tickets found matching your QUERY hash.

=cut

sub find_matching_tickets {
    my $self                   = shift;
    my %query                  = (@_);
    my $last_changeset_seen_dt = $self->_only_pull_tickets_modified_after()
      || DateTime->from_epoch( epoch => 0, time_zone  => 'GMT', );
    
    my $issue = $self->sync_source->github->issue;

    # appending a Z to the iso8601 time as the date will be (correctly) treated as localtime
    my @updated =  $issue->repos_issues({ since => $last_changeset_seen_dt . 'Z' });

    while ($issue->has_next_page) {
        push @updated, $issue->next_page;
    }

    push @updated, $issue->repos_issues({ since => $last_changeset_seen_dt . 'Z', state => 'closed' });    
    while ($issue->has_next_page) {
        push @updated, $issue->next_page;
    }

    return \@updated;
}

sub _only_pull_tickets_modified_after {
    my $self = shift;

    my $last_pull = $self->sync_source->upstream_last_modified_date();
    return unless $last_pull;
    my $before = App::SD::Util::string_to_datetime($last_pull);
    $self->log_debug( "Failed to parse '" . $self->sync_source->upstream_last_modified_date() . "' as a timestamp. That means we have to sync ALL history") unless ($before);
    return $before;
}

=head2 find_matching_transactions { ticket => $id, starting_transaction => $num  }

Returns a reference to an array of all transactions (as hashes) on ticket $id
after transaction $num.

For GitHub, we can't get change history for tickets; we can only get comments.

=cut

sub find_matching_transactions {
    my $self     = shift;
    my %args     = validate( @_, { ticket => 1, starting_transaction => 1 } );
    my @raw_txns =
      @{ $self->sync_source->github->issue->comments( $args{ticket}->{number} ) };

    for my $comment (@raw_txns) {
        $comment->{updated_at} =
          App::SD::Util::string_to_datetime( $comment->{updated_at} );
        $comment->{created_at} =
          App::SD::Util::string_to_datetime( $comment->{created_at} );
    }

    my @txns;
    for my $txn ( sort { $a->{id} <=> $b->{id} } @raw_txns ) {
        my $txn_date = $txn->{updated_at}->epoch;

        # Skip things we know we've already pulled
        next if $txn_date < ( $args{'starting_transaction'} || 0 );

        # Skip things we've pushed
        next if (
            $self->sync_source->foreign_transaction_originated_locally(
                $txn_date, $args{'ticket'}->{number}
            )
          );

        # ok. it didn't originate locally. we might want to integrate it
        push @txns,
          {
            timestamp => $txn->{created_at},
            serial    => $txn->{id},
            object    => $txn,
          };
    }

    # if the ticket itself hasn't been created, add it to the beginning
    # of the list of transactions
    my $ticket_created =
      App::SD::Util::string_to_datetime( $args{ticket}->{created_at} );
    if ( $ticket_created->epoch >= $args{'starting_transaction'} || 0 ) {
        unshift @txns,
          {
            timestamp => $ticket_created,
            serial    => 0,
            object    => $args{ticket},
          };
    }

    $self->sync_source->log_debug('Done looking at pulled txns');

    return \@txns;
}

sub transcode_create_txn {
    my $self        = shift;
    my $txn         = shift;

    my $ticket      = $txn->{object};

    my $ticket_uuid = 
          $self->sync_source->uuid_for_remote_id($ticket->{number});
    
    my $changeset = Prophet::ChangeSet->new(
        {
            original_source_uuid => $ticket_uuid,
            original_sequence_no => 0,
            creator              => $ticket->{creator},
            created              => $txn->{timestamp}->iso8601,
        }
    );

    my $change = Prophet::Change->new(
        {
            record_type => 'ticket',
            record_uuid => $ticket_uuid,
            change_type => 'add_file',
        }
    );

    for my $prop (qw/title state owner creator milestone tags description reporter/) {
        $change->add_prop_change(
            name => $PROP_MAP{$prop} || $prop,
            new => $ticket->{$prop},
        );
    }
    
    # stringify datetime before saving
    $change->add_prop_change(
        name => $PROP_MAP{created_at},
        new  => $ticket->{created_at}->iso8601,
    );

    $change->add_prop_change(
        name => $self->sync_source->uuid . '-id',
        new => $ticket->{number},
    );

    $changeset->add_change( { change => $change } );

    $self->_include_change_comment( $changeset, $ticket_uuid, $txn->{object} );

    return $changeset;
}

# we might get return:
# 0 changesets if it was a null txn
# 1 changeset if it was a normal txn
# 2 changesets if we needed to to some magic fixups.

sub transcode_one_txn {
    my $self               = shift;
    my $txn_wrapper        = shift;
    my $ticket = shift;

    my $txn = $txn_wrapper->{object};
    if ( $txn_wrapper->{serial} == 0 ) {
        return $self->transcode_create_txn($txn_wrapper);
    }

    my $ticket_uuid =
      $self->sync_source->uuid_for_remote_id( $ticket->{number} );

    my $changeset = Prophet::ChangeSet->new(
        {
            original_source_uuid => $ticket_uuid,
            original_sequence_no => $txn->{id},
            creator =>
              $self->resolve_user_id_to( email_address => $txn->{user}->{login} ),
            created => $txn->{created_at}->iso8601,
        }
    );

    $self->_include_change_comment( $changeset, $ticket_uuid, $txn );

    return unless $changeset->has_changes;
    return $changeset;
}

sub _include_change_comment {
    my $self        = shift;
    my ($changeset, $ticket_uuid, $txn) = @_;

    if (exists $txn->{comments}) {
        # comments don't have comments
        return;
    }

    my $comment = $self->new_comment_creation_change();

    # TODO markdown!
    if ( my $content = $txn->{body} ) {
        if ( $content !~ /^\s*$/s ) {
            $comment->add_prop_change(
                name => 'created',
                new  => $txn->{created_at}->ymd . ' ' . $txn->{created_at}->hms,
            );
            $comment->add_prop_change(
                name => 'creator',
                new =>
                  $self->resolve_user_id_to( email_address => $txn->{user}->{login} ),
            );
            $comment->add_prop_change( name => 'content', new => $content );
            $comment->add_prop_change(
                name => 'content_type',
                new  => 'text/plain',
            );
            $comment->add_prop_change( name => 'ticket', new => $ticket_uuid, );

            $changeset->add_change( { change => $comment } );
        }
    }

}

sub translate_prop_status {
    my $self   = shift;
    my $status = shift;
    return lc($status);
}

# TODO resolve user and get their email?
sub resolve_user_id_to {
    my $self = shift;
    my $to   = shift;
    my $id   = shift;
    return $id . '@github';
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;
1;
