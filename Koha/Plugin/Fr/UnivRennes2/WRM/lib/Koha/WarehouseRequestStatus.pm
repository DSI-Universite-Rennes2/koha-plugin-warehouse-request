package Koha::WarehouseRequestStatus;

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

use Koha::Database;

use Koha::WarehouseRequest;

use base qw(Koha::Objects);

=head1 NAME

Koha::WarehouseRequestStatus - Koha Curbside Pickup Policies Object set class

=head1 API

=head2 Class Methods

=cut

=head3 type

=cut

sub Pending {
    return 'PENDING';
}

sub Processing {
    return 'PROCESSING';
}

sub Waiting {
    return 'WAITING';
}

sub Completed {
    return 'COMPLETED';
}

sub Canceled {
    return 'CANCELED';
}

sub GetStatusLabel {
    my $status = shift;
    my %labels = (
        'PENDING'    => 'En attente',
        'PROCESSING' => 'En traitement',
        'WAITING'    => 'Disponible',
        'COMPLETED'  => 'Termin&eacute;e',
        'CANCELED'   => 'Annul&eacute;e'
    );
    return $labels{$status};
}

=head1 AUTHOR

Gwendal Joncour <gwendal.joncour@univ-rennes2.fr>
Julien Sicot <julien.sicot@univ-rennes2.fr>
Kyle M Hall <kyle@bywatersolutions.com>

=cut

1;