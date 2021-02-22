# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Koha::Plugins::Handler;
use Koha::Plugin::Fr::UnivRennes2::WRM;

my $since = $ARGV[0];

if ( defined $since || !($since =~ /^\d+$/) ) {
    exit 1;
}

my $plugin = Koha::Plugin::Fr::UnivRennes2::WRM->new();
my @wr = Koha::WarehouseRequests->archived_since( $since );
my $counter = 0;
foreach my $wr ( @wr ) {
    $counter += $wr->delete();
}
print "$counter/".(scalar @wr)." warehouse requests has been deleted.\n";
exit 0;