package App::SD::CLI::Command::Ticket::Show;
use Moose;
extends 'Prophet::CLI::Command::Show';
with 'App::SD::CLI::Command';
with 'App::SD::CLI::Model::Ticket';


sub by_creation_date { $a->prop('created') cmp $b->prop('created') };

override run => sub {
    my $self = shift;

    $self->require_uuid;
    my $record = $self->_load_record;

    print "\n= METADATA\n\n";
    super();

    my @attachments = sort by_creation_date @{$record->attachments};
    if (@attachments) {
        print "\n= ATTACHMENTS\n\n";
        print $_->format_summary . "\n"
            for @attachments;
    }

    my @comments = sort by_creation_date @{$record->comments};
    if (@comments) {
        print "\n= COMMENTS\n\n";
        for my $comment (@comments) {
            my $creator = $comment->prop('creator');
            my $created = $comment->prop('created');
            my $content = $comment->prop('content') || '';
            print "$creator: " if $creator;
            print "$created\n$content\n\n";
        }
    }

    # allow user to not display history by specifying the --skip-history
    # arg or setting disable_ticket_show_history_by_default config item to a
    # true value (can be overridden with --show-history)
    if (!$self->has_arg('skip-history') && (!$self->app_handle->config->get(
                'disable_ticket_show_history_by_default') ||
            $self->has_arg('show-history'))) {
        print "\n= HISTORY\n\n";
        print $record->history_as_string;
    }
};

__PACKAGE__->meta->make_immutable;
no Moose;

1;
