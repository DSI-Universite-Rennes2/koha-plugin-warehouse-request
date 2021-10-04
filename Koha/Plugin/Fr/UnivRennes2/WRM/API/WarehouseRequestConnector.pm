package Koha::Plugin::Fr::UnivRennes2::WRM::API::WarehouseRequestConnector;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use CGI;
use Authen::CAS::Client;
use Koha::AuthorisedValues;
use Koha::Items;
use Koha::Library;
use Koha::Plugin::Fr::UnivRennes2::WRM;
use Mojo::Base 'Mojolicious::Controller';

sub update_status {
    require Koha::WarehouseRequest;
    require Koha::WarehouseRequests;
    require Koha::WarehouseRequestStatus;

    my $c = shift->openapi->valid_input or return;
    
    my $id = $c->validation->param('id');
    my $action = $c->validation->param('action');
    my $notes = $c->validation->param('notes');
    
    my $wr = Koha::WarehouseRequests->find($id);
    my $plugin = Koha::Plugin::Fr::UnivRennes2::WRM->new();
    
    if ($wr->status eq 'CANCELED' || $wr->status eq 'COMPLETED') {
        return $c->render(
            status => 403,
            openapi => {
                error => 'Modification impossible car la demande est déjà '.lc Koha::WarehouseRequestStatus::GetStatusLabel($wr->status).'.'
            }
        );
    }
    
    if ($wr) {
        if ( $action eq 'cancel' ) {
            $wr = $wr->cancel( $notes );
        }
        elsif ( $action eq 'wait' ) {
            $wr = $wr->wait( $plugin->get_days_to_keep );
        }
        elsif ( $action eq 'process' ) {
            $wr = $wr->process();
        }
        elsif ( $action eq 'complete' ) {
            $wr = $wr->complete();
        }
        return $c->render(
            status => 200,
            openapi => {
                success => Mojo::JSON->true
            }
        );
    }
    return $c->render(
        status => 404,
        openapi => {
            error => "Warehouse request not found"
        }
    );
}

sub check_requestable_items {
    my $c = shift->openapi->valid_input or return;
    
    my $wr = Koha::Plugin::Fr::UnivRennes2::WRM->new();
        
    my $biblionumber = $c->validation->param('biblionumber');
    my $biblio = Koha::Biblios->find($biblionumber);
    
    my @warehouse_branches;
    if (my $wlib = $wr->retrieve_data('warehouse_branches')) {
        @warehouse_branches = split(',', $wlib);
    }
    
    my @warehouse_locations;
    if (my $wloc = $wr->retrieve_data('warehouse_locations')) {
        @warehouse_locations = split(',', $wloc);
    }
    
    my @warehouse_itemtypes;
    if (my $wit = $wr->retrieve_data('warehouse_itemtypes')) {
        @warehouse_itemtypes = split(',', $wit);
    }
    
    my @warehouse_notforloan;
    if (my $wnfl = $wr->retrieve_data('warehouse_notforloan')) {
        @warehouse_notforloan = split(',', $wnfl);
    }
   
    my $criterias = {
        biblionumber => $biblionumber,
        location => \@warehouse_locations,
        homebranch => \@warehouse_branches,
        itype => \@warehouse_itemtypes,
        notforloan => \@warehouse_notforloan
    };
    
    if ($biblio->itemtype ne 'REVUE') {
#         $criterias->{itemnumber} = {
#             'NOT IN' => \"(SELECT itemnumber FROM warehouse_requests WHERE status NOT IN ('COMPLETED','CANCELED'))"
#         };
        $criterias->{onloan} = undef
    }
    
    my @items = Koha::Items->search($criterias);
    
    
    @items = map { _item_to_api( $_ ) } @items;
    
#     unless ($items) {
#         return $c->render( status => 404, openapi => { error => "Object not found." } );
#     }
#     
    return $c->render( status => 200, openapi =>  \@items );
   
   }

sub request {
    require Koha::WarehouseRequest;
    require Koha::WarehouseRequests;
    require Koha::WarehouseRequestStatus;

    my $c = shift->openapi->valid_input or return;
    
    my $contenttype = $c->res->headers->content_type('application/javascript');
    my $callback = $c->validation->param('callback') // 'callback';
    $callback =~ s/[^a-zA-Z0-9\.\_\[\]]//g;
    
    my $user;
    if ( $c->stash('koha.user') ) {
        $user = $c->stash('koha.user');
    } else {
        my $cas_url = C4::Context->preference('casServerUrl');
        my $cas = Authen::CAS::Client->new( $cas_url );
        my $ticket = $c->validation->param('ticket');
        my $uri = $c->req->url->to_abs;
        my $userid;
        if ( !defined $ticket || $ticket eq '' ) {
            my $login_url = $cas->login_url($uri);
            return $c->redirect_to($login_url);
        } else {
            $uri =~ s/[&?]ticket=[^&]+//g;
            my $val = $cas->service_validate( $uri, $ticket);
            if ( $val->is_success() ) {
                $userid = $val->user();
            }
        }
        $user = Koha::Patrons->find({ userid => $userid });
    }

    unless ( $user ) {
        return $c->render(
            status => 200,
            data => "$callback({state:'failed',error:'USER_NOT_FOUND'});",
            format => $contenttype
        );
    }
    
    my $biblionumber = $c->validation->param('biblionumber'); 
    my $itemnumber   = $c->validation->param('itemnumber');
    my $callnumber   = $c->validation->param('callnumber');
    my $type         = $c->validation->param('type');
    my $volume       = $c->validation->param('volume') // '';
    my $issue        = $c->validation->param('issue') // '';
    my $year         = $c->validation->param('year') // '';
    my $message      = $c->validation->param('message');
    my $branchcode   = $c->validation->param('branchcode');
    
    my $item;
    
    if ( $type eq 'JOUR' ) {
        if (($volume eq "" && $issue eq "") || $year eq "") {
            return $c->render(
                status => 200,
                data => "$callback({state:'failed',error:'MISSING_INFO_JOURNAL'});",
                format => $contenttype
            );
        }
        $item = Koha::Items->search({
            biblionumber => $biblionumber
        })->single();
    } else {
        $item = Koha::Items->find({ itemnumber => $itemnumber });
                if (Koha::WarehouseRequests->search({
            borrowernumber => $user->borrowernumber,
            itemnumber => $item->itemnumber,
            status => 'PENDING'
        })->count > 0) {
            return $c->render(
                status => 200,
                data => "$callback({state:'failed',error:'ALREADY_REQUESTED'});",
                format => $contenttype
            );
        }
    }
    
    if ( $user->is_expired ) {
        return $c->render(
            status => 200,
            data => "$callback({state:'failed',error:'USER_NOT_ALLOWED'});",
            format => $contenttype
        );
    }
    
    my $wr = Koha::WarehouseRequest->new({
        borrowernumber => $user->borrowernumber,
        biblionumber => $item->biblionumber,
        branchcode => $branchcode,
        itemnumber => $item->itemnumber,
        volume => $volume,
        issue => $issue,
        date => $year,
        patron_notes => $message
    })->store();
    
    if ( $wr ) {
        return $c->render(
            status => 200,
            data => "$callback({state:'success'});",
            format => $contenttype
        );
    }
    return $c->render(
        status => 500,
        data => "$callback({error:'Erreur lors de la transmission de la demande'});",
        format => $contenttype
    );
}

sub list {
    require Koha::WarehouseRequest;
    require Koha::WarehouseRequests;
    require Koha::WarehouseRequestStatus;

    my $c = shift->openapi->valid_input or return;
    
    my $borrowernumber = $c->validation->param('borrowernumber');
    my $status = $c->validation->param('status');
    my $params = {
        archived => 0
    };
    if ( defined $status && $status ne '' ) {
        $params->{status} = $status;
    } else {
        unless ($borrowernumber) {
            my $user = $c->stash('koha.user');
            $borrowernumber = $user->borrowernumber;
        }
        if ( defined $borrowernumber && $borrowernumber ne '' ) {
            $params->{borrowernumber} = $borrowernumber;
        } else {
            return $c->render(
                status => 404,
                openapi => {
                    error => "Utilisateur non trouvé"
                }
            );
        }
    }
    
    my $requests = Koha::WarehouseRequests->search($params);
    
    my @requests_list = $requests->as_list;
    @requests_list = map { _to_api( $_->TO_JSON, $_->biblio, $_->item, $_->branch, $_->borrower, (defined $status && $status ne '') ) } @requests_list;
  
    return $c->render(
        status => 200,
        openapi => \@requests_list
    );
}

sub count {
    require Koha::WarehouseRequest;
    require Koha::WarehouseRequests;
    require Koha::WarehouseRequestStatus;

    my $c = shift->openapi->valid_input or return;
    
    my $biblionumber = $c->validation->param('biblionumber');
    my $arguments;
    if ($biblionumber) {
        $arguments->{biblionumber} = $biblionumber;
        $arguments->{status} = { 'NOT IN' => \"('COMPLETED','CANCELED')" };
    } else {
        $arguments->{status} = 'PROCESSING'
    }
    return $c->render(
        status => 200,
        openapi => {
            count => Koha::WarehouseRequests->search($arguments)->count()
        }
    );
}

sub _to_api {
    require Koha::WarehouseRequest;
    require Koha::WarehouseRequests;
    require Koha::WarehouseRequestStatus;

    my ($request, $biblio, $item, $branch, $borrower, $bystatus) = @_;
   $request->{branchname} = $item->holding_branch->branchname; 
   $request->{biblio} = {
        "title" => $biblio->title,
        "author" => $biblio->author
    };
    $request->{item} = {
        "holdingbranch" => $item->holding_branch->branchname,
        "location" => Koha::AuthorisedValues->find_by_koha_field( { kohafield => 'items.location', authorised_value => $item->location } )->lib,
        "itemtype" => Koha::ItemTypes->find( $item->effective_itemtype )->description,
        "itemcallnumber" => $item->itemcallnumber,
        "barcode" => $item->barcode
    };
    if ($bystatus) {
        $request->{borrower} = {
            "firstname" => $borrower->firstname,
            "surname" => $borrower->surname,
            "phone" => $borrower->phone
        };
    }
    $request->{statusstr} = Koha::WarehouseRequestStatus::GetStatusLabel($request->{status});
    return $request;
}


sub _item_to_api {
    my ($item) = @_;
    my $obj = {
	    "itemnumber" => $item->itemnumber,
        "holdingbranch" => $item->holding_branch->branchname,
        "location" => Koha::AuthorisedValues->find_by_koha_field( { kohafield => 'items.location', authorised_value => $item->location } )->lib,
        "itemtype" => Koha::ItemTypes->find( $item->effective_itemtype )->description,
        "itemcallnumber" => $item->itemcallnumber,
        "barcode" => $item->barcode
    };
    return $obj;
}

1;
