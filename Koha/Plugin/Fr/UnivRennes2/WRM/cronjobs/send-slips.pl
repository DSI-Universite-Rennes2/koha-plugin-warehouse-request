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

use CGI qw( -utf8 );

use Compress::Bzip2 qw(:all);
use MIME::Base64;
use Mojo::JSON qw(decode_json encode_json);
use Net::AMQP::RabbitMQ;
use Try::Tiny;

use Koha::Libraries; 
use Koha::Plugins::Handler;
use Koha::Plugin::Fr::UnivRennes2::WRM;

my $plugin = Koha::Plugin::Fr::UnivRennes2::WRM->new();
my ($rmq_server, $rmq_port, $rmq_vhost, $rmq_exchange, $rmq_user, $rmq_pwd) = $plugin->get_rmq_configuration();

my $query = new CGI;

my $branches = Koha::Libraries->search()->unblessed;
foreach my $branch ( @$branches ) {
    my $is_enabled = $plugin->is_enabled ;
    
    if ($is_enabled) {
        my @pending_wr = Koha::WarehouseRequests->pending($branch->{branchcode});
        
        foreach my $wr (@pending_wr) {
            my $pdf = Koha::WarehouseRequestSlip::getTicket($query, $wr->id, 1);
            my $stream = bzdeflateInit() or die "Cannot create a deflation stream\n";
            my ($output, $status) = $stream->bzdeflate($pdf);
            $status == BZ_OK or die "deflation failed\n";
            my $bz2 = $output;
            ($output, $status) = $stream->bzclose();
            $status == BZ_OK or die "deflation failed\n";
            $bz2 .= $output;
            my $b64 = encode_base64($bz2);
            
            if ( defined $b64 ) {
                try {
                    my $mq = Net::AMQP::RabbitMQ->new();
                    $mq->connect($rmq_server, {
                        user => $rmq_user,
                        password => $rmq_pwd,
                        port => $rmq_port,
                        vhost => $rmq_vhost
                    });
                    $mq->channel_open(1);
                    my %message = (
                        metadata => {
                            creation_date => DateTime->now( time_zone => 'local' )->strftime("%Y-%m-%dT%H:%M:%S%z"),
                            source => 'koha',
                            context => 'print_ticket'
                        },
                        content => {
                            ticketid => $wr->id,
                            destination => $branch->{branchcode},
                            payload => $b64
                        }
                    );
                    $mq->publish(1, '', encode_json(\%message), { exchange => $rmq_exchange });
                    $mq->disconnect();
                    $wr->process();
                } catch {
                    die "Error sending AMQP message";
                }
            }
        }
    }
}