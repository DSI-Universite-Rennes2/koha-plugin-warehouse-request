package Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequest;

# Copyright ByWater Solutions 2015
#
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

use Carp;
use DateTime;

use C4::Context;
use Koha::Calendar;
use Koha::Database;
use Koha::Patrons;
use Koha::Biblios;
use Koha::Items;
use Koha::Libraries;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status;
use Koha::DateUtils qw(dt_from_string);

use base qw(Koha::Object);

=head1 NAME

Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequest - Koha Warehouse Request Object class

=head1 API

=head2 Class Methods

=cut

=head3 open

=cut

sub open {
    my ($self) = @_;

    $self->status(Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::Pending);
    $self->SUPER::store();
    $self->notify();
    return $self;
    
}

=head3 process

=cut

sub process {
    my ($self) = @_;

    $self->status(Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::Processing);
    $self->store();
    return $self;
}

=head3 process

=cut

sub wait {
    my ($self, $days_to_keep ) = @_;
    my $deadline = $self->calculate_deadline( $days_to_keep );

    $self->status(Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::Waiting);
    $self->deadline( $deadline );
    $self->store();
    $self->notify();
    return $self;
}

=head3 complete

=cut

sub complete {
    my ($self) = @_;

    $self->status(Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::Completed);
    $self->store();
    return $self;
}

=head3 cancel

=cut

sub cancel {
    my ( $self, $notes ) = @_;

    $self->status(Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::Canceled);
    $self->notes($notes) if $notes;
    $self->store();
    $self->notify();
    return $self;
}

=head3 archive

=cut

sub archive {
    my ( $self ) = @_;
    $self->archived(1);
    $self->store();
    return $self;
}

=head3 set_deadline

=cut

sub calculate_deadline {
    my ( $self, $days_to_keep ) = @_;
    my $calendar = Koha::Calendar->new(branchcode => $self->branchcode);
    my $deadline = DateTime->now( time_zone => C4::Context->tz() );
    while ( $days_to_keep > 0 ) {
        $deadline = $calendar->next_open_day($deadline);
        $days_to_keep--;
    }
    my $dtf = Koha::Database->new->schema->storage->datetime_parser;
    return $dtf->format_date($deadline);
}

=head3 notify

=cut

sub notify {
    my ($self) = @_;

    my $status = $self->status;

    require C4::Letters;
    my $letter = C4::Letters::GetPreparedLetter(
        module                 => 'circulation',
        letter_code            => "WR_$status",
        message_transport_type => 'email',
        tables                 => {
            borrowers        => $self->borrowernumber,
            biblio           => $self->biblionumber,
            biblioitems      => $self->biblionumber,
            items            => $self->itemnumber,
            branches         => $self->branchcode,
        },
        substitute             => {
            warehouse_request_notes => $self->notes
        }
    );
    if ( $letter ) {
        C4::Letters::EnqueueLetter({
            letter                 => $letter,
            borrowernumber         => $self->borrowernumber,
            message_transport_type => 'email',
        }) or warn "can't enqueue letter $letter";
    } 
}

=head3 status_label

Returns the label version of the status

=cut

sub status_label {
    my ($self) = @_;
    
    return Koha::Plugin::Fr::UnivRennes2::WRM::Object::Status::GetStatusLabel($self->status);
}

=head3 biblio

Returns the Koha::Biblio object for this article request

=cut

sub biblio {
    my ($self) = @_;

    $self->{_biblio} ||= Koha::Biblios->find( $self->biblionumber() );

    return $self->{_biblio};
}

=head3 item

Returns the Koha::Item object for this article request

=cut

sub item {
    my ($self) = @_;

    $self->{_item} ||= Koha::Items->find( $self->itemnumber() );

    return $self->{_item};
}

=head3 borrower

Returns the Koha::Patron object for this article request

=cut

sub borrower {
    my ($self) = @_;

    $self->{_borrower} ||= Koha::Patrons->find( $self->borrowernumber() );

    return $self->{_borrower};
}

=head3 branch

Returns the Koha::Library object for this article request

=cut

sub branch {
    my ($self) = @_;

    $self->{_branch} ||= Koha::Libraries->find( $self->branchcode() );

    return $self->{_branch};
}

=head3 store

Override the default store behavior so that new opan requests
will have notifications sent.

=cut

sub store {
    my ($self) = @_;

    if ( $self->in_storage() ) {
        my $now = dt_from_string();
        $self->updated_on($now);

        return $self->SUPER::store();
    }
    else {
        $self->open();
        return $self->SUPER::store();
    }
}

=head3 _type

=cut

sub _type {
    return 'WarehouseRequest';
}

=head1 AUTHOR

Gwendal Joncour <gwendal.joncour@univ-rennes2.fr>
Julien Sicot <julien.sicot@univ-rennes2.fr>
Kyle M Hall <kyle@bywatersolutions.com>

=cut

1;
