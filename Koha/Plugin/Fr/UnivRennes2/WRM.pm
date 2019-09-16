package Koha::Plugin::Fr::UnivRennes2::WRM;

use utf8;
use Modern::Perl;
use base qw(Koha::Plugins::Base);

use Mojo::JSON qw(decode_json encode_json);
use C4::Auth;
use Date::Calc qw(Date_to_Days);
use C4::Utils::DataTables::Members;
use C4::Output;
use C4::Context;
use C4::Koha; #GetItemTypes
use C4::Letters;
use C4::Members;
use Koha::AuthorisedValue;
use Koha::AuthorisedValues;
use Koha::AuthorisedValueCategory;
use Koha::AuthorisedValueCategories;
use Koha::Biblios;
use Koha::Database;
use Koha::DateUtils;
use Koha::Items;
use Koha::Patrons;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::Slip;

## Here we set our plugin version
our $VERSION = '{VERSION}';

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Demandes magasin',
    author          => 'Sicot Julien/Joncour Gwendal',
    date_authored   => '2019-06-25',
    date_updated    => '{UPDATE_DATE}',
    minimum_version => '18.110000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Permet de gérer les demandes de document en magasin.',
};

my $reason_category = 'WR_REASON';
my %default_reasons = (
    'ISSUE'    => 'Document déjà emprunté',
    'MANQ'     => 'Document manquant',
    'DAMAGED'  => 'Document trop abimé pour être consulté',
    'TOOLATE'  => 'Délai de mise à disposition (3 jours) dépassé',
    'ERROR'    => 'Erreur de cote',
    'NEEDINFO' => 'Informations complémentaires requises',
    'CANCELED' => 'Annulé par le lecteur'
);

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    my $self = $class->SUPER::new($args);
    return $self;
}

sub tool {
    my ( $self, $args ) = @_;

    my $query = $self->{'cgi'};
    
    if ( defined $query->param('op') ) {
        if ( $query->param('op') eq 'creation' ) {
            $self->creation();
        } elsif ( $query->param('op') eq 'ticket' ) {
            $self->ticket();
        }
    } else {
        my $template = $self->get_template({ file => 'templates/warehouse-requests.tt' });
    
        my $branchcode = defined( $query->param('branchcode') ) ? $query->param('branchcode') : C4::Context->userenv->{'branch'};
        my $reasonsloop = GetAuthorisedValues($reason_category);
        
        $template->param(
            branchcode                    => $branchcode,
            warehouse_requests_pending    => scalar Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->pending($branchcode),
            warehouse_requests_processing => scalar Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->processing($branchcode),
            warehouse_requests_waiting    => scalar Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->waiting($branchcode),
            warehouse_requests_completed  => scalar Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->completed($branchcode),
            warehouse_requests_canceled   => scalar Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->canceled($branchcode),
            reasonsloop     => $reasonsloop,
        );
        
        $self->output_html( $template->output );
    }
}

sub creation {
    my ( $self, $args ) = @_;
    
    my $query = $self->{'cgi'};
    my $template = $self->get_template({ file => 'templates/request-warehouse.tt' });
    
    my $expiry = 0; # flag set if patron account has expired
    my $today = output_pref({ dt => dt_from_string, dateformat => 'iso', dateonly => 1 });
    
    my $action            = $query->param('action') || q{};
    my $biblionumber      = $query->param('biblionumber');
    my $patron_cardnumber = $query->param('patron_cardnumber');
    my $patron_id         = $query->param('patron_id');
    
    my $biblio = Koha::Biblios->find($biblionumber);
    
    my @warehouse_locations;
    if (my $wloc = $self->retrieve_data('warehouse_locations')) {
        @warehouse_locations = split(',', $wloc);
    }
    my $criterias = {
        biblionumber => $biblionumber,
        location => \@warehouse_locations
    };
    if ($biblio->itemtype ne 'REVUE') {
        $criterias->{itemnumber} = {
            'NOT IN' => \"(SELECT itemnumber FROM warehouse_requests WHERE status NOT IN ('COMPLETED','CANCELED'))"
        };
        $criterias->{onloan} = undef
    }
    my @items = Koha::Items->search($criterias);
    my $patron =
        $patron_id         ? Koha::Patrons->find($patron_id)
      : $patron_cardnumber ? Koha::Patrons->find( { cardnumber => $patron_cardnumber } )
      : undef;
    
    if ( $action eq 'create' ) {
        my $borrowernumber = $query->param('borrowernumber');
        my $branchcode     = $query->param('branchcode');
    
        my $itemnumber   = $query->param('itemnumber')   || undef;
        my $volume       = $query->param('volume')       || undef;
        my $issue        = $query->param('issue')        || undef;
        my $date         = $query->param('date')         || undef;
        my $patron_name  = $query->param('patron_name')  || undef;
        my $patron_notes = $query->param('patron_notes') || undef;
    
        my $wr =  Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequest->new({
            borrowernumber => $borrowernumber,
            biblionumber   => $biblio->biblionumber,
            branchcode     => $branchcode,
            itemnumber     => $itemnumber,
            volume         => $volume,
            issue          => $issue,
            date           => $date,
            patron_name    => $patron_name,
            patron_notes   => $patron_notes
        })->store();
    }
    
    if ( !$patron && $patron_cardnumber ) {
        my $results = C4::Utils::DataTables::Members::search(
            {
                searchmember => $patron_cardnumber,
                dt_params    => { iDisplayLength => -1 },
            }
        );
    
        my $patrons = $results->{patrons};
    
        if ( scalar @$patrons == 1 ) {
            $patron = Koha::Patrons->find( $patrons->[0]->{borrowernumber} );
        }
        elsif (@$patrons) {
            $template->param( patrons => $patrons );
        }
        else {
            $template->param( no_patrons_found => $patron_cardnumber );
        }
    }
    
    if ($patron) {
        
        my $borrower = $patron->unblessed;
        my $expiry_date = $borrower->{dateexpiry};
    
        if ($expiry_date and $expiry_date ne '0000-00-00' and
            Date_to_Days(split /-/,$today) > Date_to_Days(split /-/,$expiry_date)) {
            $expiry = 1;
        }
    }
    
    $template->param(
        biblio => $biblio,
        items => \@items,
        patron => $patron,
        expiry => $expiry,
        requests => scalar Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests->search({ biblionumber => $biblio->biblionumber, archived => 0 })
    );
    
    $self->output_html( $template->output );
}

sub ticket {
    my ( $self, $args ) = @_;
    
    my $query = $self->{'cgi'};
    my $id = $query->param('id');
    
    my $slip = Koha::Plugin::Fr::UnivRennes2::WRM::Object::Slip::getTicket($query, $id);
    
    print "Content-type: application/pdf\nCharset: utf-8\n\n";
    binmode(STDOUT);
    print $slip;
}

sub get_days_to_keep {
    my ( $self, $args ) = @_;
    my $days_to_keep = $self->retrieve_data('days_to_keep') // 3;
    return $days_to_keep;
}

sub get_days_since_archived {
    my ( $self, $args ) = @_;
    my $days_to_keep = $self->retrieve_data('days_since_archived') // 15;
    return $days_to_keep;
}

sub get_rmq_configuration {
    my ( $self, $args ) = @_;
    my $rmq_server = $self->retrieve_data('rmq_server') // '';
    my $rmq_port = $self->retrieve_data('rmq_port') // '';
    my $rmq_vhost = $self->retrieve_data('rmq_vhost') // '';
    my $rmq_exchange = $self->retrieve_data('rmq_exchange') // '';
    my $rmq_user = $self->retrieve_data('rmq_user') // '';
    my $rmq_pwd = $self->retrieve_data('rmq_pwd') // '';
    return ($rmq_server, $rmq_port, $rmq_vhost, $rmq_exchange, $rmq_user, $rmq_pwd);
}

sub get_ticket_template {
    my ( $self, $args ) = @_;
    $self->{'cgi'} = new CGI unless ( $self->{'cgi'} );
    return $self->get_template({ file => 'templates/printslip.tt' });
}

sub opac_head {
    my ( $self ) = @_;

    return q|
        <style>
            #warehouse-requests th, #warehouse-requests .nowrap {
                white-space: nowrap;
            }
        </style>
    |;
}

sub opac_js {
    my ( $self ) = @_;

    return q@
        <script>
            if ($('#opac-user').length > 0) {
                var tabs = $( '#opac-user-views' ).tabs();
                var ul = tabs.find( 'ul' );
                $('<li><a href="#warehouse-requests" id="wrm-tab">Demandes de document (?)</a></li>').appendTo( ul );
                $('<div id="warehouse-requests">Chargement...</div>').appendTo( tabs );
                tabs.tabs( "refresh" );
                refreshWarehouseRequests();
            }
            
            function refreshWarehouseRequests() {
                $.get( "/api/v1/contrib/wrm/list", function( data ) {
                    $('#wrm-tab').text('Demandes de document ('+data.length+')');
                    var result =$('#warehouse-requests').empty();
                    result.append(`
                    <table class="table table-bordered table-striped dataTable no-footer" role="grid">
                        <tbody>
                        </tbody>
                    </table>
                    `);
                    if (data.length > 0) {
                        result.find('table').prepend(`
                            <caption>Demandes de document (`+data.length+` en tout) </caption>
                            <thead>
                                <tr>
                                    <th>Informations</th>
                                    <th>Demandé le</th>
                                    <th>A retirer avant le</th>
                                    <th>Statut</th>
                                    <th>Site de retrait</th>
                                    <th></th>
                                </tr>
                            </thead>
                        `);
                        for ( var i = 0 ; i < data.length ; i++ ) {
                            console.log(data[i]);
                            var cd = new Date(data[i].created_on);
                            var rd = new Date(data[i].deadline);
                            var infoBlock = '<a href="/bib/'+data[i].biblionumber+'" title="'+data[i].biblio.title+'">'+data[i].biblio.title+'</a> '+data[i].biblio.author+' <span class="label">(Seulement '+data[i].item.itemcallnumber+')</span>';
                            var extInfoBlock = [];
                            if (data[i].volume != '')   extInfoBlock.push('<span class="label">Volume(s) : '+data[i].volume+'</span>');
                            if (data[i].issue != '')    extInfoBlock.push('<span class="label">Numéro(s) : '+data[i].issue+'</span>');
                            if (data[i].date != '')     extInfoBlock.push('<span class="label">Date : '+data[i].date+'</span>');
                            if (extInfoBlock.length > 0)    infoBlock += '<br />'+extInfoBlock.join(' | ');
                            result.find('tbody').append(`
                                <tr>
                                    <td>`+infoBlock+`</td>
                                    <td>`+cd.toLocaleDateString()+' '+cd.toLocaleTimeString()+`</td>
                                    <td>`+rd.toLocaleDateString()+`</td>
                                    <td class="nowrap">`+data[i].statusstr+`</td>
                                    <td>`+data[i].branchname+`</td>
                                    <td>`+(['CANCELED','COMPLETED'].indexOf(data[i].status) < 0 ? '<a data-id="'+data[i].id+'" class="cancel-wr btn btn-danger"><i class="fa fa-close"></i> Annuler</a>' : '')+`</td>
                                </tr>
                            `);
                        }
                        $('.cancel-wr').click(function() {
                            if (confirm('Êtes-vous sûr(e) de vouloir annuler votre demande ?')) {
                                var id = $(this).attr('data-id');
                                $.post( "/api/v1/contrib/wrm/cancel/"+id , function( data ) {
                                    alert('Votre demande a été annulée avec succès');
                                    refreshWarehouseRequests();
                                });
                            }
                        });
                    } else {
                        result.find('tbody').append('<tr><td>Aucune demande en cours</td></tr>');
                    }
                });
            }
        </script>
    @;
}

sub intranet_head {
    my ( $self ) = @_;

    return q|
        <style>
            #warehouse-requests table {
                width: 100%;
            }
            #warehouse-requests th, #warehouse-requests .nowrap {
                white-space: nowrap;
            }
            #warehouse-requests .btn-danger {
                color: white;
            }
        </style>
    |;
}

sub intranet_js {
    my ( $self ) = @_;

    return q@
        <script>
            // Home button injection
            if ( $('#main_intranet-main').length > 0 ) {
                $.get({
                    url: "/api/v1/contrib/wrm/count",
                    cache: true,
                    success: function( data ) {
                        if (data.count > 0) {
                            var wrlink  = `<div class="pending-info" id="warehouse_requests_pending">
                                <a href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool#warehouse-requests-processing">Demandes magasin</a>:
                                <span class="pending-number-link">`+data.count+`</span>
                            </div>`;
                            if ( $('#area-pending').length > 0 ) {
                                $('#area-pending').prepend(wrlink);
                            } else {
                                $('#container-main > div.row > div.col-sm-9 > div.row:last-child div.col-sm-12').append('<div id="area-pending">'+wrlink+'</div>');
                            }
                        }
                    }
                });
            }
            // Circ homepage button injection
            if ( $('#circ_circulation-home').length > 0 ) {
                var wrbutton = '<li><a class="circ-button" href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool" title="Demandes magasins"><i class="fa fa-file-text-o"></i> Demandes magasins</a></li>';
                var requestsMenu = $('i.fa-newspaper-o').parents('ul.buttons-list');
                if ( requestsMenu.length > 0 ) {
                    requestsMenu.prepend(wrbutton);
                } else {
                    $('#circ_circulation-home div.main > div.row:first-child > div:last-child').prepend('<h3>Demandes des adhérents</h3><ul class="buttons-list">'+wrbutton+'</ul>');
                }
            }
            // Member tabs table injection
            if ( $('#circ_circulation, #pat_moremember').length > 0 ) {
                var tabs = $( '#patronlists, #finesholdsissues' ).tabs();
                tabs.find('ul li:last').before('<li><a href="#warehouse-requests" id="wrm-tab">? Demandes magasin</a></li>');
                tabs.find('div:last').before('<div id="warehouse-requests">Chargement...</div>');
                tabs.tabs( "refresh" );
                refreshWarehouseRequests();
            }
            // Catalog detail link
            let searchParams = new URLSearchParams(window.location.search);
            $('#catalog_detail #toolbar, #catalog_moredetail #toolbar').append('<div class="btn-group"><a id="placehold" class="btn btn-default btn-sm" href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool&op=creation&biblionumber='+searchParams.get('biblionumber')+'"><i class="fa fa-file-text-o"></i> Demande magasin</a></div>');
            if ( $('body.circ div#menu, body.catalog div#menu').length > 0 ) {
                $('body.circ div#menu ul:first-child, body.catalog div#menu ul:first-child').append('<li><a id="wr-menu-link" href="/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AFr%3A%3AUnivRennes2%3A%3AWRM&method=tool&op=creation&biblionumber='+searchParams.get('biblionumber')+'">Demandes magasin (?)</a></li>');
                $.get({
                    url: "/api/v1/contrib/wrm/count?biblionumber="+searchParams.get('biblionumber'),
                    cache: true,
                    success: function( data ) {
                        $('#wr-menu-link').text('Demandes magasin ('+data.count+')');
                    }
                });
                if ( $('#circ_request-warehouse').length > 0 ) {
                    $('#wr-menu-link').parent().addClass('active');
                }
            }
            
            function refreshWarehouseRequests() {
                var borrowernumber = $('.patroninfo ul li.patronborrowernumber').text().replace(/\D/g, '');
                $.get({
                    url: "/api/v1/contrib/wrm/list/"+borrowernumber,
                    cache: true,
                    success: function( data ) {
                        $('#wrm-tab').text( data.length+' Demandes magasin');
                        var result =$('#warehouse-requests').empty();
                        result.append(`
                        <table role="grid">
                            <tbody>
                            </tbody>
                        </table>
                        `);
                        if (data.length > 0) {
                            result.find('table').prepend(`
                                <thead>
                                    <tr>
                                        <th>Informations</th>
                                        <th>Demandé le</th>
                                        <th>A chercher avant le</th>
                                        <th>Statut</th>
                                        <th>Site de retrait</th>
                                        <th></th>
                                    </tr>
                                </thead>
                            `);
                            for ( var i = 0 ; i < data.length ; i++ ) {
                                console.log(data[i]);
                                var cd = new Date(data[i].created_on);
                                var rd = new Date(data[i].deadline);
                                var infoBlock = '<a class="strong" href="/cgi-bin/koha/catalogue/detail.pl?biblionumber='+data[i].biblionumber+'" title="'+data[i].biblio.title+'">'+data[i].biblio.title+'</a> '+data[i].biblio.author+' <span class="label">(Seulement '+data[i].item.itemcallnumber+')</span>';
                                var extInfoBlock = [];
                                if (data[i].volume != '')   extInfoBlock.push('<span class="label">Volume(s) : '+data[i].volume+'</span>');
                                if (data[i].issue != '')    extInfoBlock.push('<span class="label">Numéro(s) : '+data[i].issue+'</span>');
                                if (data[i].date != '')     extInfoBlock.push('<span class="label">Date : '+data[i].date+'</span>');
                                if (extInfoBlock.length > 0)    infoBlock += '<br />'+extInfoBlock.join(' | ');
                                result.find('tbody').append(`
                                    <tr>
                                        <td>`+infoBlock+`</td>
                                        <td>`+cd.toLocaleDateString()+' '+cd.toLocaleTimeString()+`</td>
                                        <td>`+rd.toLocaleDateString()+`</td>
                                        <td class="nowrap">`+decodeURIComponent(data[i].statusstr)+`</td>
                                        <td>`+data[i].branchname+`</td>
                                        <td class="text-center">`+
                                            (['CANCELED','COMPLETED'].indexOf(data[i].status) < 0 ?
                                                '<div class="btn-group">'+
                                                    ( data[i].status == 'WAITING' ? '<a data-id="'+data[i].id+'" title="Terminer la demande" class="complete-wr btn-xs btn btn-success"><i class="fa fa-fw fa-check"></i> Terminer</a>' : '' )+ 
                                                    '<a data-id="'+data[i].id+'" title="Annuler la demande" class="cancel-wr btn-xs btn btn-danger"><i class="fa fa-fw fa-close"></i> Annuler</a>'+
                                                '</div>'
                                            : '')
                                        +`</td>
                                    </tr>
                                `);
                            }
                            $('#warehouse-requests table').dataTable($.extend(true, {}, dataTablesDefaults, {
                                "sDom": 't',
                                "aaSorting": [[ 1, "desc" ]],
                                "aoColumnDefs": [
                                    { "aTargets": [ -1 ], "bSortable": false, "bSearchable": false }
                                ],
                                "bPaginate": false
                            }));
                            $('#circ_circulation .complete-wr, #pat_moremember .complete-wr').click(function() {
                                var id = $(this).attr('data-id');   
                                $.ajax({
                                    type: "POST",
                                    url: "/api/v1/contrib/wrm/update_status",
                                    data: {
                                        id: id,
                                        action: 'complete',
                                    },
                                    success: function( data ) {
                                        alert('La demande a été terminée avec succès');
                                        refreshWarehouseRequests();
                                    },
                                    error: function( data ) {
                                        alert( data.error );
                                    }
                                });
                            });
                            $('#circ_circulation .cancel-wr, #pat_moremember .cancel-wr').click(function() {    
                                var notes = prompt('Raison de l\'annulation :');
                                if (notes !== null) {
                                    var id = $(this).attr('data-id');
                                    $.ajax({
                                        type: "POST",
                                        url: "/api/v1/contrib/wrm/update_status",
                                        data: {
                                            id: id,
                                            action: 'cancel',
                                            notes: notes,
                                        },
                                        success: function( data ) {
                                            alert('La demande a été annulée avec succès');
                                            refreshWarehouseRequests();
                                        },
                                        error: function( data ) {
                                            alert( data.error );
                                        }
                                    });
                                }
                            });
                        } else {
                            result.find('tbody').append('<tr><td>L\'adhérent n\'a pas de demandes magasin en cours.</td></tr>');
                        }
                    }
                });
            }
        </script>
    @;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    
    my $template = $self->get_template({ file => 'templates/configure.tt' });
    if ( $cgi->param('save') ) {
        my $myconf;
        $myconf->{days_to_keep} = $cgi->param('days_to_keep');
        $myconf->{days_since_archived} = $cgi->param('days_since_archived');
        $myconf->{warehouse_locations} = join(",", $cgi->multi_param('warehouse_locations'));
        $myconf->{rmq_server} = $cgi->param('rmq_server');
        $myconf->{rmq_port} = $cgi->param('rmq_port');
        $myconf->{rmq_vhost} = $cgi->param('rmq_vhost');
        $myconf->{rmq_exchange} = $cgi->param('rmq_exchange');
        $myconf->{rmq_user} = $cgi->param('rmq_user');
        if ( $cgi->param('rmq_pwd') ) {
            if ( $cgi->param('rmq_pwd_conf') && $cgi->param('rmq_pwd') eq $cgi->param('rmq_pwd_conf') ) {
                $myconf->{rmq_pwd} = $cgi->param('rmq_pwd');
            } else {
                $template->param( 'config_error' => 'Les deux saisies du mot de passe RabbitMQ doivent être identiques.' );
                $myconf = undef;
            }
        }
        if ( $myconf ) {
            $self->store_data($myconf);
            $template->param( 'config_success' => 'La configuration du plugin a été enregistrée avec succès !' );
        }
    }
    my @warehouse_locations;
    if (my $wloc = $self->retrieve_data('warehouse_locations')) {
        @warehouse_locations = split(',', $wloc);
    }
    my $locations = GetAuthorisedValues('LOC');
    $template->param(
        'days_to_keep' => $self->retrieve_data('days_to_keep'),
        'days_since_archived' => $self->retrieve_data('days_since_archived'),
        'locations' => $locations,
        'warehouse_locations' => \@warehouse_locations,
        'rmq_server' => $self->retrieve_data('rmq_server'),
        'rmq_port' => $self->retrieve_data('rmq_port'),
        'rmq_vhost' => $self->retrieve_data('rmq_vhost'),
        'rmq_exchange' => $self->retrieve_data('rmq_exchange'),
        'rmq_user' => $self->retrieve_data('rmq_user')
    );
    $self->output_html( $template->output() );
}

sub install {
    my ( $self, $args ) = @_;

    my $success = C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS `warehouse_requests` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `borrowernumber` int(11) NOT NULL,
            `biblionumber` int(11) NOT NULL,
            `itemnumber` int(11) DEFAULT NULL,
            `branchcode` varchar(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULL,
            `volume` text,
            `issue` text,
            `date` text,
            `patron_name` text,
            `patron_notes` text,
            `status` enum('PENDING','PROCESSING','WAITING','COMPLETED','CANCELED') NOT NULL DEFAULT 'PENDING',
            `notes` text,
            `created_on` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_on` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
            `deadline` timestamp NULL DEFAULT NULL,
            `archived` tinyint(1) NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`),
            KEY `borrowernumber` (`borrowernumber`),
            KEY `biblionumber` (`biblionumber`),
            KEY `itemnumber` (`itemnumber`),
            KEY `branchcode` (`branchcode`),
            CONSTRAINT `warehouse_requests_ibfk_1` FOREIGN KEY (`borrowernumber`) REFERENCES `borrowers` (`borrowernumber`) ON DELETE CASCADE ON UPDATE CASCADE,
            CONSTRAINT `warehouse_requests_ibfk_2` FOREIGN KEY (`biblionumber`) REFERENCES `biblio` (`biblionumber`) ON DELETE CASCADE ON UPDATE CASCADE,
            CONSTRAINT `warehouse_requests_ibfk_3` FOREIGN KEY (`itemnumber`) REFERENCES `items` (`itemnumber`) ON DELETE SET NULL ON UPDATE CASCADE,
            CONSTRAINT `warehouse_requests_ibfk_4` FOREIGN KEY (`branchcode`) REFERENCES `branches` (`branchcode`) ON DELETE SET NULL ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;");
    $success = $success && C4::Context->dbh->do( "
        INSERT INTO `letter` (`module`, `code`, `branchcode`, `name`, `is_html`, `title`, `content`, `message_transport_type`) VALUES
        ('circulation', 'WR_CANCELED', '', '[BU Rennes 2] Demande de document rejetée', 1, '[BU Rennes 2] Demande de document rejetée', '<p>Bonjour <<borrowers.firstname>> <<borrowers.surname>>,</p>\r\n\r\n<p>Vous avez effectué une demande pour le document suivant :</p>\r\n\r\n<ul style=\"list-style-type:none;\">\r\n  <li>Titre : <em><<biblio.title>></em></li>\r\n  <li>Auteur: <em><<biblio.author>></em></li>\r\n  <li>Cote : <em><<items.itemcallnumber>></em></li>\r\n</ul>\r\n\r\n<p>Nous ne pouvons malheureusement y donner suite pour la raison suivante&nbsp;: <br \\>\r\n<strong><<warehouse_request_notes>></strong>.</p>\r\n\r\n<p>N''hésitez pas à nous contacter pour des informations complémentaires.</p>\r\n\r\n<p>Cordialement,</p>\r\n<table border=\"0\" cellpadding=\"0\" cellspacing=\"2\" width=\"600\"><tbody><tr><td valign=\"top\" width=\"120\"><div align=\"center\"><a href=\"http://www.bu.univ-rennes2.fr\"><img src=\"https://www.bu.univ-rennes2.fr/sites/all/themes/bootstrap_bur2/img/logo_bu_rennes2.png\" alt=\"Logo BU Rennes 2\" moz-do-not-send=\"false\" style=\"padding-bottom:5px;\" border=\"0\" height=\"auto\" width=\"120\"></a><br> <a href=\"https://www.facebook.com/bibliotheques.univ.rennes2/\"><img moz-do-not-send=\"false\" alt=\"Logo Facebook\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/facebook_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  <a href=\"http://twitter.com/BURennes2\"><img alt=\"Logo Twitter\" moz-do-not-send=\"false\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/twitter_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  </div><br></td><td valign=\"top\"><small>\r\n<b><<branches.branchname>></b><br>\r\nBU Rennes 2<br>\r\n02 99 14 12 75<br>\r\n <a href=\"https://www.bu.univ-rennes2.fr\" title=\"BU en ligne\">www.bu.univ-rennes2.fr</a>\r\n</td></tr></tbody></table>', 'email'),
        ('circulation', 'WR_COMPLETED', '', 'Warehouse Request - Email - Completed', 0, 'Warehouse Request Completed', 'Bonjour <<borrowers.firstname>> <<borrowers.surname>>,\r\n\r\nNous avons le plaisir de vous informer que le document que vous avez demandé est à votre disposition à l''accueil de la BU centrale.\r\n\r\nPour rappel, il s''agissait d''une demande concernant :\r\n\r\nTitre : <<biblio.title>>\r\nAuteur: <<biblio.author>>\r\nCote : <<items.itemcallnumber>>\r\n\r\nPour l''emprunter, rendez-vous à l''accueil de la BU Centrale. Vous pouvez également le consulter sur place si vous le désirez.\r\n\r\nN''hésitez pas à nous contacter si toutefois vous n''étiez pas en mesure de vous déplacer pour retirer le document.\r\n\r\nBien cordialement,\r\nLes Bibliothèque de l''Université Rennes 2', 'email'),
        ('circulation', 'WR_PENDING', '', '[BU Rennes 2] Votre demande de document', 0, '[BU Rennes 2] Votre demande de document', 'Bonjour <<borrowers.firstname>> <<borrowers.surname>>,\r\n\r\nNous accusons bonne réception de votre demande concernant le document :\r\n\r\nTitre : <<biblio.title>>\r\nAuteur: <<biblio.author>>\r\nCote : <<items.itemcallnumber>>\r\n\r\nVotre demande sera traitée dans la journée (ou le lendemain pour les demandes effectuées après 18h00). Le document sera ensuite mis à disposition sur une étagère près de l''accueil de la BU centrale. Cinq levées ont lieu par jour, deux le matin et trois l''après-midi.\r\n\r\nCordialement,\r\nUniversité Rennes 2 - Bibliothèques', 'email'),
        ('circulation', 'WR_PROCESSING', '', '[BU Rennes 2] Prise en charge de votre demande', 1, '[BU Rennes 2] Prise en charge de votre demande', '<p>Bonjour <<borrowers.firstname>> <<borrowers.surname>>,</p>\r\n\r\n<p>Nous avons le plaisir de vous annoncer que votre demande pour le document <em><<biblio.title>></em> est bien prise en charge.</p>\r\n\r\n<p><strong>Vous recevrez bientôt un e-mail vous informant de la mise à disposition de ce dernier.</strong></p>\r\n\r\n<p><strong>Ne vous déplacez pas avant de recevoir cette confirmation.</strong></p>\r\n\r\n<p>N''hésitez pas à nous contacter pour toute information complémentaire.</p>\r\n\r\n<p>Cordialement,</p>\r\n<table border=\"0\" cellpadding=\"0\" cellspacing=\"2\" width=\"600\"><tbody><tr><td valign=\"top\" width=\"120\"><div align=\"center\"><a href=\"http://www.bu.univ-rennes2.fr\"><img src=\"https://www.bu.univ-rennes2.fr/sites/all/themes/bootstrap_bur2/img/logo_bu_rennes2.png\" alt=\"Logo BU Rennes 2\" moz-do-not-send=\"false\" style=\"padding-bottom:5px;\" border=\"0\" height=\"auto\" width=\"120\"></a><br> <a href=\"https://www.facebook.com/bibliotheques.univ.rennes2/\"><img moz-do-not-send=\"false\" alt=\"Logo Facebook\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/facebook_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  <a href=\"http://twitter.com/BURennes2\"><img alt=\"Logo Twitter\" moz-do-not-send=\"false\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/twitter_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  </div><br></td><td valign=\"top\"><small>\r\n<b><<branches.branchname>></b><br>\r\nBU Rennes 2<br>\r\n02 99 14 12 75<br>\r\n <a href=\"https://www.bu.univ-rennes2.fr\" title=\"BU en ligne\">www.bu.univ-rennes2.fr</a>\r\n</td></tr></tbody></table>', 'email'),
        ('circulation', 'WR_SLIP', '', 'Warehouse Request - Print Slip', 1, 'Test', '<div class=\"message\">\r\n        <pre>\r\n            <div class=\"user\"><<borrowers.surname>> <<borrowers.firstname>> </div>\r\n            <div class=\"requestdate\"><strong>Ticket n° <<warehouse_request_id>>, le <<warehouse_request_created_on>></strong></div>\r\n            <div class=\"content\">		\r\n                <div class=\"typedoc\"><strong><<biblioitems.itemtype>></strong></div>		\r\n                <div class=\"requestdoc\"><<biblio.title>> / <<biblio.author>> ;  <<biblioitems.publicationyear>></div>\r\n                <div class=\"barcode\"><<items.itemcallnumber>></div>\r\n                <div class=\"volnum\"><strong>Vol.</strong> <<warehouse_request_volume>> - <strong>N°</strong> <<warehouse_request_issue>> - <strong>Année : </strong> <<warehouse_request_date>></div>\r\n                <div class=\"note\"><<warehouse_request_patron_notes>></div>\r\n            </div>\r\n        </pre>\r\n     </div>', 'print'),
        ('circulation', 'WR_WAITING', '', '[BU Rennes 2] Document disponible', 1, '[BU Rennes 2] Document disponible', '<p>Bonjour <<borrowers.firstname>> <<borrowers.surname>>,</p>\r\n\r\n<p>Votre document est <strong>disponible</strong>, il peut être retiré à l''accueil de la BU centrale.</p>\r\n<p>Pour rappel, il s''agissait d''une demande concernant :\r\n\r\n<ul style=\"list-style-type:none;\">\r\n  <li>Titre : <em><<biblio.title>></em></li>\r\n  <li>Auteur: <em><<biblio.author>></em></li>\r\n  <li>Cote : <em><<items.itemcallnumber>></em></li>\r\n</ul>\r\n<strong>Vous avez jusqu''à 3 jours pour venir consulter ou emprunter ce dernier. Au-delà et sans nouvelle de votre part, il sera remis en rayon.</strong></p>\r\n\r\n<p>N''hésitez pas à nous contacter si toutefois vous n''étiez pas en mesure de vous déplacer. </p>\r\n\r\n<p>Cordialement,</p>\r\n<table border=\"0\" cellpadding=\"0\" cellspacing=\"2\" width=\"600\"><tbody><tr><td valign=\"top\" width=\"120\"><div align=\"center\"><a href=\"http://www.bu.univ-rennes2.fr\"><img src=\"https://www.bu.univ-rennes2.fr/sites/all/themes/bootstrap_bur2/img/logo_bu_rennes2.png\" alt=\"Logo BU Rennes 2\" moz-do-not-send=\"false\" style=\"padding-bottom:5px;\" border=\"0\" height=\"auto\" width=\"120\"></a><br> <a href=\"https://www.facebook.com/bibliotheques.univ.rennes2/\"><img moz-do-not-send=\"false\" alt=\"Logo Facebook\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/facebook_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  <a href=\"http://twitter.com/BURennes2\"><img alt=\"Logo Twitter\" moz-do-not-send=\"false\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/twitter_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  </div><br></td><td valign=\"top\"><small>\r\n<b><<branches.branchname>></b><br>\r\nBU Rennes 2<br>\r\n02 99 14 12 75<br>\r\n <a href=\"https://www.bu.univ-rennes2.fr\" title=\"BU en ligne\">www.bu.univ-rennes2.fr</a>\r\n</td></tr></tbody></table>', 'email');
    ");
    $success = $success && symlink(
        C4::Context->config('pluginsdir')."/Koha/Plugin/Fr/UnivRennes2/WRM/Schema/WarehouseRequest.pm",
        C4::Context->config('intranetdir')."/Koha/Schema/Result/WarehouseRequest.pm"
    );
    if ( $success ) {
        my $avc = Koha::AuthorisedValueCategory->new({ category_name => $reason_category });
        eval { $avc->store };
        if ( $@ ) {
            $success = 0;
        } else {
            $success = 1;
            while ( $success and my ($key, $value) = each %default_reasons ) {
                my $av = Koha::AuthorisedValue->new({
                    category => $reason_category,
                    authorised_value => $key,
                    lib => $value || undef,
                    lib_opac =>  $value || undef,
                    imageurl => '',
                });
                eval {
                    $av->store;
                };
                if ( $@ ) {
                    $success = 0;
                }
            }
        }
    }
    return $success;
}

#sub upgrade {}

sub uninstall {
    my ( $self, $args ) = @_;
    my $success = C4::Context->dbh->do("DROP TABLE IF EXISTS `warehouse_requests`;");
    $success = $success && C4::Context->dbh->do("DELETE FROM letter WHERE code IN ('WR_CANCELED', 'WR_COMPLETED', 'WR_PENDING', 'WR_PROCESSING', 'WR_SLIP', 'WR_WAITING');");
    if ( -l C4::Context->config('intranetdir')."/Koha/Schema/Result/WarehouseRequest.pm") {
        $success = $success && unlink C4::Context->config('intranetdir')."/Koha/Schema/Result/WarehouseRequest.pm";
    }
    if ( $success ) {
        my @av_reasons = Koha::AuthorisedValues->new->search({ category => $reason_category });
        while ( $success and my $av = each @av_reasons ) {
            my $deleted = eval {$av->delete};
            if ( $@ or not $deleted ) {
                $success = 0;
            }
        }
    }
    if ( $success ) {
        my $avc = Koha::AuthorisedValueCategories->find({ category_name => $reason_category, });
        eval { $avc->delete };
        if ( $@ ) {
            $success = 0;
        }
    }
    return $success;
}

sub api_routes {
    my ( $self, $args ) = @_;
    
    my $spec_str = $self->mbf_read('API/openapi.json');
    my $spec     = decode_json($spec_str);
    
    return $spec;
}

sub api_namespace {
    my ( $self ) = @_;
    
    return 'wrm';
}

1;
