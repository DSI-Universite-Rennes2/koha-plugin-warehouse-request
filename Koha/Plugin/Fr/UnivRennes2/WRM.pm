package Koha::Plugin::Fr::UnivRennes2::WRM;

use utf8;
use Modern::Perl;
use base qw(Koha::Plugins::Base);

use Mojo::JSON qw(decode_json encode_json);
use C4::Auth;
use C4::Output;
use C4::Context;
use C4::Koha; #GetItemTypes
use C4::Letters;
use Koha::AuthorisedValue;
use Koha::AuthorisedValues;
use Koha::AuthorisedValueCategory;
use Koha::AuthorisedValueCategories;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::WarehouseRequests;
use Koha::Plugin::Fr::UnivRennes2::WRM::Object::Slip;
use Koha::Database;

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
    'NEEDINFO' => 'Informations complémentaires requises'
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
    
    if ( defined $query->param('op') and $query->param('op') eq 'ticket' ) {
        $self->ticket();
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

sub get_ticket_template {
    my ( $self, $args ) = @_;
    $self->{'cgi'} = new CGI unless ( $self->{'cgi'} );
    return $self->get_template({ file => 'templates/printslip.tt' });
}

#sub opac_head {}
#sub opac_js {}
#sub intranet_head {}
#sub intranet_js {}
#sub configure {}

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
        ('circulation', 'WR_COMPLETED', '', 'Article Request - Email - Completed', 0, 'Article Request Completed', 'Bonjour <<borrowers.firstname>> <<borrowers.surname>>,\r\n\r\nNous avons le plaisir de vous informer que le document que vous avez demandé est à votre disposition à l''accueil de la BU centrale.\r\n\r\nPour rappel, il s''agissait d''une demande concernant :\r\n\r\nTitre : <<biblio.title>>\r\nAuteur: <<biblio.author>>\r\nCote : <<items.itemcallnumber>>\r\n\r\nPour l''emprunter, rendez-vous à l''accueil de la BU Centrale. Vous pouvez également le consulter sur place si vous le désirez.\r\n\r\nN''hésitez pas à nous contacter si toutefois vous n''étiez pas en mesure de vous déplacer pour retirer le document.\r\n\r\nBien cordialement,\r\nLes Bibliothèque de l''Université Rennes 2', 'email'),
        ('circulation', 'WR_PENDING', '', '[BU Rennes 2] Votre demande de document', 0, '[BU Rennes 2] Votre demande de document', 'Bonjour <<borrowers.firstname>> <<borrowers.surname>>,\r\n\r\nNous accusons bonne réception de votre demande concernant le document :\r\n\r\nTitre : <<biblio.title>>\r\nAuteur: <<biblio.author>>\r\nCote : <<items.itemcallnumber>>\r\n\r\nVotre demande sera traitée dans la journée (ou le lendemain pour les demandes effectuées après 18h00). Le document sera ensuite mis à disposition sur une étagère près de l''accueil de la BU centrale. Cinq levées ont lieu par jour, deux le matin et trois l''après-midi.\r\n\r\nCordialement,\r\nUniversité Rennes 2 - Bibliothèques', 'email'),
        ('circulation', 'WR_PROCESSING', '', '[BU Rennes 2] Prise en charge de votre demande', 1, '[BU Rennes 2] Prise en charge de votre demande', '<p>Bonjour <<borrowers.firstname>> <<borrowers.surname>>,</p>\r\n\r\n<p>Nous avons le plaisir de vous annoncer que votre demande pour le document <em><<biblio.title>></em> est bien prise en charge.</p>\r\n\r\n<p><strong>Vous recevrez bientôt un e-mail vous informant de la mise à disposition de ce dernier.</strong></p>\r\n\r\n<p><strong>Ne vous déplacez pas avant de recevoir cette confirmation.</strong></p>\r\n\r\n<p>N''hésitez pas à nous contacter pour toute information complémentaire.</p>\r\n\r\n<p>Cordialement,</p>\r\n<table border=\"0\" cellpadding=\"0\" cellspacing=\"2\" width=\"600\"><tbody><tr><td valign=\"top\" width=\"120\"><div align=\"center\"><a href=\"http://www.bu.univ-rennes2.fr\"><img src=\"https://www.bu.univ-rennes2.fr/sites/all/themes/bootstrap_bur2/img/logo_bu_rennes2.png\" alt=\"Logo BU Rennes 2\" moz-do-not-send=\"false\" style=\"padding-bottom:5px;\" border=\"0\" height=\"auto\" width=\"120\"></a><br> <a href=\"https://www.facebook.com/bibliotheques.univ.rennes2/\"><img moz-do-not-send=\"false\" alt=\"Logo Facebook\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/facebook_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  <a href=\"http://twitter.com/BURennes2\"><img alt=\"Logo Twitter\" moz-do-not-send=\"false\" src=\"https://www.univ-rennes2.fr/system/files/UHB/SERVICE-COMMUNICATION/twitter_logo.png\" border=\"0\" height=\"20\" width=\"20\"></a>  </div><br></td><td valign=\"top\"><small>\r\n<b><<branches.branchname>></b><br>\r\nBU Rennes 2<br>\r\n02 99 14 12 75<br>\r\n <a href=\"https://www.bu.univ-rennes2.fr\" title=\"BU en ligne\">www.bu.univ-rennes2.fr</a>\r\n</td></tr></tbody></table>', 'email'),
        ('circulation', 'WR_SLIP', '', 'Article Request - Print Slip', 1, 'Test', '<div class=\"message\">\r\n        <pre>\r\n            <div class=\"user\"><<borrowers.surname>> <<borrowers.firstname>> </div>\r\n            <div class=\"requestdate\"><strong>Ticket n° <<warehouse_request_id>>, le <<warehouse_request_created_on>></strong></div>\r\n            <div class=\"content\">		\r\n                <div class=\"typedoc\"><strong><<biblioitems.itemtype>></strong></div>		\r\n                <div class=\"requestdoc\"><<biblio.title>> / <<biblio.author>> ;  <<biblioitems.publicationyear>></div>\r\n                <div class=\"barcode\"><<items.itemcallnumber>></div>\r\n                <div class=\"volnum\"><strong>Vol.</strong> <<warehouse_request_volume>> - <strong>N°</strong> <<warehouse_request_issue>> - <strong>Année : </strong> <<warehouse_request_date>></div>\r\n                <div class=\"note\"><<warehouse_request_patron_notes>></div>\r\n            </div>\r\n        </pre>\r\n     </div>', 'print'),
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
