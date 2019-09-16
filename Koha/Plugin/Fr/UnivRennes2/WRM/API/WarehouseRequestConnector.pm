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
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequest;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status;
use Mojo::Base 'Mojolicious::Controller';

sub update_status {
    my $c = shift->openapi->valid_input or return;
    
    my $id = $c->validation->param('id');
    my $action = $c->validation->param('action');
    my $notes = $c->validation->param('notes');
    
    my $wr = Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->find($id);
    my $plugin = Koha::Plugin::Fr::UnivRennes2::WRM->new();
    
    if ($wr->status eq 'CANCELED' || $wr->status eq 'COMPLETED') {
        return $c->render(
            status => 403,
            openapi => {
                error => 'Modification impossible car la demande est déjà '.lc Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::GetStatusLabel($wr->status).'.'
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

sub cancel {
    my $c = shift->openapi->valid_input or return;
    
    my $id = $c->validation->param('id');
    my $user = $c->stash('koha.user');
    my $wr = Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->find($id);
    
    if ( $wr->borrowernumber != $user->borrowernumber || grep { $_ eq $wr->status } ['COMPLETED','CANCELED']  || $wr->archived ) {
        return $c->render(
            status => 403,
            openapi => {
                error => 'Vous n\'avez pas le droit d\'annuler cette demande'
            }
        );
    }
    
    my $av = Koha::AuthorisedValues->find({ category => 'WR_REASON', authorised_value => 'CANCELED' });
    $wr->cancel($av->lib);
    
    return $c->render(
        status => 200,
        openapi => {
            success => Mojo::JSON->true
        }
    );
}

sub request {
    my $c = shift->openapi->valid_input or return;
    
    my $ticket = $c->validation->param('ticket');
    my $cas = Authen::CAS::Client->new( C4::Context->preference('casServerUrl') );
    
    my $uri = $c->req->url->to_abs;
    $uri =~ s/[&?]ticket=.+//g;
    my $val = $cas->service_validate( $uri, $ticket );

    my $userid;
    if ( $val->is_success() ) {
        $userid = $val->user();
    } else {
        warn $val->error() if $val->is_error();
        warn $val->message() if $val->is_failure();
    }

    my $user = Koha::Patrons->find({ userid => $userid });

    unless ( $user ) {
        return $c->render(
            status => 200,
            openapi => {
                state => 'failed',
                error => 'USER_NOT_FOUND'
            }
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
    
    my $branchcode = "BU";
    
    my $item;
    
    if ( $type eq 'JOUR' ) {
        if (($volume eq "" && $issue eq "") || $year eq "") {
            return $c->render(
                status => 200,
                openapi => {
                    state => 'failed',
                    error => 'MISSING_INFO_JOURNAL'
                }
            );
        }
        $item = Koha::Items->search({
            biblionumber => $biblionumber,
            homebranch => $branchcode
        })->single();
    } else {
        $item = Koha::Items->find({ itemnumber => $itemnumber });
    }
    
    if ( $user->is_expired || $user->is_debarred ) {
        return $c->render(
            status => 200,
            openapi => {
                state => 'failed',
                error => 'USER_NOT_FOUND'
            }
        );
    }
    
    my $wr = Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequest->new({
        borrowernumber => $user->borrowernumber,
        biblionumber => $item->biblionumber,
        branchcode => $branchcode,
        itemnumber => $item->itemnumber,
        volume => $volume,
        issue => $issue,
        date => $year,
        patron_note => $message
    })->store();
    
    if ( $wr ) {
        return $c->render(
            status => 200,
            openapi => {
                state => 'success',
            }
        );
    }
    return $c->render(
        status => 500,
        openapi => {
            error => "Erreur lors de la transmission de la demande"
        }
    );
}

sub list {
    my $c = shift->openapi->valid_input or return;
    
    my $borrowernumber = $c->validation->param('borrowernumber');
    unless ($borrowernumber) {
        my $user = $c->stash('koha.user');
        $borrowernumber = $user->borrowernumber;
    }
    unless ($borrowernumber) {
        return $c->render(
            status => 404,
            openapi => {
                error => "Utilisateur non trouvé"
            }
        );
    }
    
    my $requests = Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->search({ borrowernumber => $borrowernumber, archived => 0 });
    
    my @requests_list = $requests->as_list;    
    @requests_list = map { _to_api( $_->TO_JSON, $_->biblio, $_->item, $_->branch ) } @requests_list;
  
    return $c->render(
        status => 200,
        openapi => \@requests_list
    );
}

sub count {
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
            count => Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->search($arguments)->count()
        }
    );
}

sub _to_api {
    my ($request, $biblio, $item, $branch) = @_;
    $request->{branchname} = $branch->branchname;
    $request->{biblio} = {
        "title" => $biblio->title,
        "author" => $biblio->author
    };
    $request->{item} = {
        "location" => Koha::AuthorisedValues->find_by_koha_field( { kohafield => 'items.location', authorised_value => $item->location } )->lib,
        "itemcallnumber" => $item->itemcallnumber
    };
    $request->{statusstr} = Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::GetStatusLabel($request->{status});
    return $request;
}

1;