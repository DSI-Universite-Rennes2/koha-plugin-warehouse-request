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

use C4::Calendar;
use Koha::Libraries; 
use Koha::Plugins::Handler;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::Slip;

my $rmq_server = 'mq.uhb.fr';
my $rmq_user = 'koha';
my $rmq_pwd = 'xpjaPnSXcXHNCPvZ';
my $rmq_port = '5672';
my $rmq_vhost = 'testing';
my $rmq_exchange = 'exchange_koha_print_tickets';

my $query = new CGI;

my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
$year+=1900;
$mon+=1;

my $branches = Koha::Libraries->search()->unblessed;
foreach my $branch ( @$branches ) {
    my $calendar = C4::Calendar->new(branchcode => $branch->{branchcode});
    if (!$calendar->isHoliday($mday,$mon,$year)) {
        my @pending_wr = Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->pending($branch->{branchcode});
        
        foreach my $wr (@pending_wr) {
            my $pdf = Koha::Plugin::Fr::UnivRennes2::WRM::Object::Slip::getTicket($query, $wr->id, 1);
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