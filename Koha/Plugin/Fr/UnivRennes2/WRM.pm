package Koha::Plugin::Fr::UnivRennes2::WRM;

use utf8;

use Modern::Perl;

use Mojo::JSON qw(decode_json encode_json);

use base qw(Koha::Plugins::Base);

use Cwd qw(abs_path);
use Encode qw(decode);
use File::Slurp qw(read_file);
use Module::Metadata;

use C4::Auth;
use Date::Calc qw(Date_to_Days);
use C4::Utils::DataTables::Members;
use C4::Output;
use C4::Context;
use C4::Koha; #GetItemTypes
use C4::Letters;
use C4::Members;
use C4::Installer qw(TableExists);
use Koha::AuthorisedValue;
use Koha::AuthorisedValues;
use Koha::AuthorisedValueCategory;
use Koha::AuthorisedValueCategories;
use Koha::Biblios;
use Koha::Database;
use Koha::DateUtils;
use Koha::Items;
use Koha::Patrons;
use Koha::Schema;

BEGIN {
    my $path = Module::Metadata->find_module_by_name(__PACKAGE__);
    $path =~ s!\.pm$!/lib!;
    unshift @INC, $path;

    require Koha::WarehouseRequestSlip;
    require Koha::WarehouseRequestStatus;
    require Koha::WarehouseRequests;
    require Koha::WarehouseRequest;
    require Koha::Schema::Result::WarehouseRequest;

    # register the additional schema classes
    Koha::Schema->register_class(WarehouseRequest => 'Koha::Schema::Result::WarehouseRequest');
    # ... and force a refresh of the database handle so that it includes
    # the new classes
    Koha::Database->schema({ new => 1 });
}


## Here we set our plugin version
our $VERSION = '{VERSION}';

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Request From Stacks / Communication des documents en Magasin',
    author          => 'Sicot Julien/Joncour Gwendal',
    date_authored   => '2019-06-25',
    date_updated    => '2021-02-24',
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
            warehouse_requests_pending    => scalar Koha::WarehouseRequests->pending($branchcode),
            warehouse_requests_processing => scalar Koha::WarehouseRequests->processing($branchcode),
            warehouse_requests_waiting    => scalar Koha::WarehouseRequests->waiting($branchcode),
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
    
    my @warehouse_branches;
    if (my $wlib = $self->retrieve_data('warehouse_branches')) {
        @warehouse_branches = split(',', $wlib);
    }
    
    my @warehouse_locations;
    if (my $wloc = $self->retrieve_data('warehouse_locations')) {
        @warehouse_locations = split(',', $wloc);
    }
    
    my @warehouse_itemtypes;
    if (my $wit = $self->retrieve_data('warehouse_itemtypes')) {
        @warehouse_itemtypes = split(',', $wit);
    }
    
    my @warehouse_notforloan;
    if (my $wnfl = $self->retrieve_data('warehouse_notforloan')) {
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
        $criterias->{itemnumber} = {
            'NOT IN' => \"(SELECT itemnumber FROM warehouse_requests WHERE status NOT IN ('COMPLETED','CANCELED') AND itemnumber IS NOT NULL)"
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
    
        my $wr =  Koha::WarehouseRequest->new({
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
        requests => scalar Koha::WarehouseRequests->search({ biblionumber => $biblio->biblionumber, archived => 0 })
    );
    
    $self->output_html( $template->output );
}

sub item_is_requestable {
    my ( $self, $itemnumber, $biblionumber ) = @_;
	my $wr = Koha::Plugin::Fr::UnivRennes2::WRM->new();

    
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
# 	    biblionumber => $biblionumber,
	    itemnumber => $itemnumber,
	    biblionumber => $biblionumber,
        location => \@warehouse_locations,
        homebranch => \@warehouse_branches,
        itype => \@warehouse_itemtypes,
        notforloan => \@warehouse_notforloan
    };
	$criterias->{itemnumber} = {
            'NOT IN' => \"(SELECT itemnumber FROM warehouse_requests WHERE status NOT IN ('COMPLETED','CANCELED'))"
        };
    $criterias->{onloan} = undef;

             return  Koha::Items->search( $criterias )->count;
# 			  return $itemnumber+ " " +$biblionumber;
   }


sub ticket {
    my ( $self, $args ) = @_;
    
    my $query = $self->{'cgi'};
    my $id = $query->param('id');
    
    my $slip = Koha::WarehouseRequestSlip::getTicket($query, $id);
    
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

sub is_enabled {
    my ( $self, $args ) = @_;
    my $is_enabled = $self->retrieve_data('warehouse_opac_enabled') // 0;
    return $is_enabled;
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
            #warehouse-requests td .label {
                padding: 2px 4px;
            }
            #warehouse-requests .reason {
                margin-top: 5px;
            }
        </style>
    |;
}

sub opac_js {
    my ($self) = @_;

    return read_file( abs_path( $self->mbf_path('js/opac.js') ), { binmode => 'utf8' } );
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
    my ($self) = @_;

    return read_file( abs_path( $self->mbf_path('js/intranet.js') ), { binmode => 'utf8' }  );
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $dir = $self->bundle_path.'/i18n';
    opendir(my $dh, $dir) || die "Can't opendir $dir: $!";
    my @files = grep { /^[^.]/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;

    my @tokens;
    foreach my $file (@files) {
        my @splitted = split(/\./, $file, -1);
        my $lang = $splitted[0];
        push @tokens, {key => $lang, text => decode("UTF-8", $self->mbf_read('i18n/'.$file))};
    }
    
    my $template = $self->get_template({ file => 'templates/configure.tt' });

    if ( $cgi->param('save') ) {
        my $myconf;
        $myconf->{days_to_keep}                 = $cgi->param('days_to_keep') || 0;
        $myconf->{days_since_archived}          = $cgi->param('days_since_archived') || 0;
        $myconf->{warehouse_branches}           = join(",", $cgi->multi_param('warehouse_branches')); 
        $myconf->{warehouse_locations}          = join(",", $cgi->multi_param('warehouse_locations'));
        $myconf->{warehouse_itemtypes}          = join(",", $cgi->multi_param('warehouse_itemtypes'));
        $myconf->{warehouse_notforloan}         = join(",", $cgi->multi_param('warehouse_notforloan'));
        $myconf->{warehouse_opac_enabled}   	= $cgi->param('warehouse_opac_enabled') || 0;
        $myconf->{warehouse_message_disabled}   = $cgi->param('warehouse_message_disabled') || undef;
        $myconf->{rmq_server}                   = $cgi->param('rmq_server');
        $myconf->{rmq_port}                     = $cgi->param('rmq_port');
        $myconf->{rmq_vhost}                    = $cgi->param('rmq_vhost');
        $myconf->{rmq_exchange}                 = $cgi->param('rmq_exchange');
        $myconf->{rmq_user}                     = $cgi->param('rmq_user');
        if ( $cgi->param('rmq_pwd') ) {
            if ( $cgi->param('rmq_pwd_conf') && $cgi->param('rmq_pwd') eq $cgi->param('rmq_pwd_conf') ) {
                $myconf->{rmq_pwd} = $cgi->param('rmq_pwd');
            } else {
                $template->param( 'config_error' => 'CONF_ERROR' );
                $myconf = undef;
            }
        }
        if ( $myconf ) {
            $self->store_data($myconf);
            $template->param( 'config_success' => 'CONF_SUCCESS' );
        }
    }
    
    my @warehouse_branches;
    if (my $wlib = $self->retrieve_data('warehouse_branches')) {
        @warehouse_branches = split(',', $wlib);
    }
    my $branches = Koha::Libraries->search( {}, { order_by => ['branchname'] } )->unblessed;
      
    my @warehouse_locations;
    if (my $wloc = $self->retrieve_data('warehouse_locations')) {
        @warehouse_locations = split(',', $wloc);
    }
    my $locations = { map { ( $_->{authorised_value} => $_->{lib} ) } Koha::AuthorisedValues->get_descriptions_by_koha_field( { frameworkcode => '', kohafield => 'items.location' }, { order_by => ['description'] } ) };
    my @locations;
	foreach (sort keys %$locations) {
		push @locations, { code => $_, description => "$_ - " . $locations->{$_} };
	}
		
	my @warehouse_itemtypes;
    if (my $wit = $self->retrieve_data('warehouse_itemtypes')) {
        @warehouse_itemtypes = split(',', $wit);
    }
	my $itemtypes = Koha::ItemTypes->search_with_localization;
    my %itemtypes = map { $_->{itemtype} => $_ } @{ $itemtypes->unblessed };
    
    my @warehouse_notforloan;
    if (my $wnfl = $self->retrieve_data('warehouse_notforloan')) {
        @warehouse_notforloan = split(',', $wnfl);
    }
    my $notforloan= { map { ( $_->{authorised_value} => $_->{lib} ) } Koha::AuthorisedValues->get_descriptions_by_koha_field( { frameworkcode => '', kohafield => 'items.notforloan' }, { order_by => ['description'] } ) };
    my @notforloan ;
	foreach (sort keys %$notforloan ) {
		push @notforloan , { code => $_, description => $notforloan->{$_} };
	}

    $template->param(
        'days_to_keep' 					=> $self->retrieve_data('days_to_keep'),
        'days_since_archived' 			=> $self->retrieve_data('days_since_archived'),
        'warehouse_branches' 			=> \@warehouse_branches,
        'branches' 						=> $branches,
        'warehouse_locations' 			=> \@warehouse_locations,
        'locations' 					=> \@locations,
        'warehouse_itemtypes' 			=> \@warehouse_itemtypes,
        'itemtypes' 					=> $itemtypes,
        'warehouse_notforloan' 			=> \@warehouse_notforloan,
        'notforloan' 					=> \@notforloan,
        'warehouse_opac_enabled' 		=> $self->retrieve_data('warehouse_opac_enabled'),
        'warehouse_message_disabled' 	=> $self->retrieve_data('warehouse_message_disabled'),
        'rmq_server' 					=> $self->retrieve_data('rmq_server'),
        'rmq_port' 						=> $self->retrieve_data('rmq_port'),
        'rmq_vhost' 					=> $self->retrieve_data('rmq_vhost'),
        'rmq_exchange' 					=> $self->retrieve_data('rmq_exchange'),
        'rmq_user' 						=> $self->retrieve_data('rmq_user'),
         tokens => \@tokens,
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
        ('circulation', 'WR_SLIP', '', 'Warehouse Request - Print Slip', 1, 'Test', '<div class=\"message\">\r\n        <pre>\r\n            <div class=\"user\"><<borrowers.surname>> <<borrowers.firstname>><<warehouse_request_patron_name>></div>\r\n            <div class=\"requestdate\"><strong>Ticket n° <<warehouse_request_id>>, le <<warehouse_request_created_on>></strong></div>\r\n            <div class=\"content\">		\r\n                <div class=\"typedoc\"><strong><<biblioitems.itemtype>></strong></div>		\r\n                <div class=\"requestdoc\"><<biblio.title>> / <<biblio.author>> ;  <<biblioitems.publicationyear>></div>\r\n                <div class=\"barcode\"><<items.itemcallnumber>></div>\r\n                <div class=\"volnum\"><strong>Vol.</strong> <<warehouse_request_volume>> - <strong>N°</strong> <<warehouse_request_issue>> - <strong>Année : </strong> <<warehouse_request_date>></div>\r\n                <div class=\"note\"><<warehouse_request_patron_notes>></div>\r\n            </div>\r\n        </pre>\r\n     </div>', 'print'),
        ('circulation', 'WR_WAITING', '', '[BU Rennes 2] Document disponible', 1, '[BU Rennes 2] Document disponible', '<p>Bonjour <<borrowers.firstname>> <<borrowers.surname>>,</p>\r\n\r\n<p>Votre document est <strong>disponible</strong>, il peut être retiré à l''accueil de la BU centrale.</p>\r\n<p>Pour rappel, il s''agissait d''une demande concernant :\r\n\r\n<ul style=\"list-style-type:none;\">\r\n  <li>Titre : <em><<biblio.title>></em></li>\r\n  <li>Auteur: <em><<biblio.author>></em></li>\r\n  <li>Cote : <em><<items.itemcallnumber>></em></li>\r\n</ul>\r\n<strong>Vous avez jusqu''à 3 jours pour venir consulter ou emprunter ce dernier. Au-delà et sans nouvelle de votre part, il sera remis en rayon.</strong></p>\r\n\r\n<p>N''hésitez pas à nous contacter si toutefois vous n''étiez pas en mesure de vous déplacer. </p>\r\n\r\n<p>Cordialement,</p>\r\n<table border=\"0\" cellpadding=\"0\" cellspacing=\"2\" width=\"600\"><tbody><tr><td valign=\"top\" width=\"120\"><div align=\"center\"><a href=\"http://www.bu.univ-rennes2.fr\"><img src=\"https://www.bu.univ-rennes2.fr/sites/all/themes/bootstrap_bur2/img/logo_bu_rennes2.png\" alt=\"Logo BU Rennes 2\" moz-do-not-send=\"false\" style=\"padding-bottom:5px;\" border=\"0\" height=\"auto\" width=\"120\"></a><br> <a href=\"https://www.facebook.com/bibliotheques.univ.rennes2/\"><img moz-do-not-send=\"false\" alt=\"Logo Facebook\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/facebook_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  <a href=\"http://twitter.com/BURennes2\"><img alt=\"Logo Twitter\" moz-do-not-send=\"false\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/twitter_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  </div><br></td><td valign=\"top\"><small>\r\n<b><<branches.branchname>></b><br>\r\nBU Rennes 2<br>\r\n02 99 14 12 75<br>\r\n <a href=\"https://www.bu.univ-rennes2.fr\" title=\"BU en ligne\">www.bu.univ-rennes2.fr</a>\r\n</td></tr></tbody></table>', 'email');
    ");

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

sub static_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('API/staticapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ( $self ) = @_;
    
    return 'wrm';
}

1;
