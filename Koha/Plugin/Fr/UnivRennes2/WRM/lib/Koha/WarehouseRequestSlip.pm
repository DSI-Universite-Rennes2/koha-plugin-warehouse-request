package Koha::WarehouseRequestSlip;

use utf8;
use Modern::Perl;

use C4::Auth;
use C4::Context;
use C4::Letters;
use PDF::WebKit;
use HTML::Barcode::Code128;
use Koha::Plugin::Fr::UnivRennes2::WRM;
use Koha::WarehouseRequests;

sub prepareTicket {
    my ($query, $id, $authnotrequired) = @_;
    
    my ( $template, $loggedinuser, $cookie ) = get_template_and_user({
        template_name   => "circ/printslip.tt",
        query           => $query,
        type            => "intranet",
        authnotrequired => $authnotrequired,
        flagsrequired   => ( $authnotrequired ? {} : { circulate => "circulate_remaining_permissions" } ),
    });
    
    my $customcss = '<link rel="stylesheet" type="text/css" href="/api/v1/contrib/wrm/static/css/slip.css" />';
    
    my $wr = Koha::WarehouseRequests->find($id);
    my $barcode = HTML::Barcode::Code128->new(
        text => ' ' x (12 - length($id)) . $id,
        bar_height => '40px',
        bar_width => '1px',
        show_text => 0,
    );
    
    my $slip = C4::Letters::GetPreparedLetter(
        module                 => 'circulation',
        letter_code            => 'WR_SLIP',
        message_transport_type => 'print',
        tables                 => {
            borrowers        => $wr->borrowernumber,
            biblio           => $wr->biblionumber,
            biblioitems      => $wr->biblionumber,
            items            => $wr->itemnumber,
            branches         => $wr->branchcode,
        },
        substitute             => {
            warehouse_request_id           => $wr->id,
            warehouse_request_created_on   => $wr->created_on,
            warehouse_request_volume       => $wr->volume // '',
            warehouse_request_issue        => $wr->issue // '',
            warehouse_request_date         => $wr->date // '',
            warehouse_request_patron_notes => $wr->patron_notes // '',
            warehouse_request_patron_name  => ( $wr->patron_name ? "<br />".$wr->patron_name : '' ),
            warehouse_request_item_location => Koha::AuthorisedValues->find_by_koha_field( { kohafield => 'items.location', authorised_value => $wr->item->location } )->lib
        }
    );
    
    $template->param(
        slip   => $customcss.$barcode->render().$slip->{content},
        plain  => !$slip->{is_html},
    );
    
    my $staffurl = C4::Context->preference('staffClientBaseURL');
    
    my $output = $template->output;
    $output =~ s/(src|href)="\//$1="$staffurl\//g;
    $output =~ s/getScript\("\//getScript\("$staffurl\//g;
    $output =~ s/\n.*css\/print_.*\n//g;
    
    utf8::encode($output);
    
   return $output;
}

sub getTicket {
    my ($query, $id, $authnotrequired) = @_;
    
    my $output = Koha::WarehouseRequestSlip::prepareTicket($query, $id, $authnotrequired);

     my $kit = PDF::WebKit->new(\$output,
        page_size => 'A6',
        margin_top => '10mm',
        margin_left => 0,
        margin_right => 0,
        margin_bottom => 0,
        encoding => 'utf-8'
    );
    # Had to set a default path to avoid error on plack
    return $kit->to_pdf('/tmp/null');
}


1;
