package App::SD::Server::Dispatcher;
use Prophet::Server::Dispatcher -base;


on qr'.' => sub {
    my $self = shift;
    my $result = $self->server->result->get('create-ticket');
        if ( $result &&  $result->success ) {
            $self->server->_send_redirect( to => '/ticket/' . $result->record_uuid );
    } else {
        next_rule;
    }
};

on qr'.' => sub {
    my $self = shift;
    my $tickets = $self->server->nav->child( tickets => label => 'Tickets', url => '/');
    $tickets->child( go => label => '<form method="GET" action="/ticket"><a href="#">Show ticket # <input type=text name=id size=3></a></form>', escape_label => 0) unless($self->server->static);


    my $milestones = $tickets->child( milestones => label => 'Milestones', url => '/milestones');
    my $items = $self->server->app_handle->setting( label => 'milestones' )->get();
    foreach my $item (@$items) {
        my $m = $milestones->child( $item => label => $item, url => '/milestone/'.$item);
        #$m->child('all' => label => 'All', url => '/milestone/'.$item.'/all');
        #$m->child('mine' => label => 'Mine', url => '/milestone/'.$item.'/mine');
        #$m->child('closed' => label => 'Closed', url => '/milestone/'.$item.'/closed');
    }
        $milestones->child( none => label => 'None', url => '/no_milestone');
    
    my $components = $tickets->child( components => label => 'Components', url => '/components');
    my $items = $self->server->app_handle->setting( label => 'components' )->get();
    foreach my $item (@$items) {
        my $c= $components->child( $item => label => $item, url => '/component/'.$item);
        #$c->child('all' => label => 'All', url => '/component/'.$item.'/all');
        #$c->child('mine' => label => 'Mine', url => '/component/'.$item.'/mine');
        #$c->child('closed' => label => 'Closed', url => '/component/'.$item.'/closed');


    }
    $components->child('None' => label => 'None', url => '/no_component');

    $self->server->nav->child( create => label => 'New ticket', url => '/ticket/new') unless($self->server->static);
    $self->server->nav->child( home => label => 'Home', url => '/');


    next_rule;

};


under 'POST' => sub {
    on qr'^ticket/([\w\d-]+)/edit$' => sub { shift->server->_send_redirect( to => '/ticket/' . $1 ); };
    on qr'^(?!records)$' => sub { shift->server->_send_redirect( to => $1 ); };
};


under 'GET' => sub {
    on qr'^(milestone|component)/([\w\d-]+)$' => sub {
        my $name = $1;
        my $type = $2;
        shift->show_template( $name => $type );
    };

    under 'ticket' => sub {
        on '' => sub {
            my $self = shift;
            if ( my $id = $self->server->cgi->param('id') ) {
                $self->server->_send_redirect( to => "/ticket/$id/view" );
            } else {
                next_rule;
            }
        };

        on 'new'                 => sub { shift->show_template('new_ticket') };
        on qr'^([\w\d-]+)/?$'    => sub { shift->server->_send_redirect( to => "/ticket/$1/view" ) };
        on qr'^([\w\d-]+)/edit$' => sub { shift->show_template( 'edit_ticket', $1 ) };
        on qr'^([\w\d-]+)/history$' => sub { shift->show_template( 'show_ticket_history', $1 ) };
        on qr'^([\w\d-]+)/view$'    => sub { shift->show_template( 'show_ticket', $1 ) };
    };
};

redispatch_to 'Prophet::Server::Dispatcher';


sub show_template {
    if(ref($_[0])) { 
        # called in oo context. do it now
        my $self = shift;
        my $template = shift;
        $self->server->show_template($template, @_);
    } else {

    my $template = shift;
    return sub {
        my $self = shift;
        $self->server->show_template($template, @_);
    };
    }
}

1;
