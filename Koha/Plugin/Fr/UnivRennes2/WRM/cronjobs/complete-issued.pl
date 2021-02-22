#! /usr/bin/perl
use strict;
use C4::Context;
use Modern::Perl;
use Koha::Plugins::Handler;
use Koha::Plugin::Fr::UnivRennes2::WRM;

my $dbh = C4::Context->dbh;
my $sth = $dbh->prepare("
    SELECT id
    FROM warehouse_requests
    JOIN issues USING (itemnumber)
    JOIN biblioitems USING (biblionumber)
    WHERE status = 'WAITING'
    AND itemtype <> 'REVUE';
");
$sth->execute();

while( my @request = $sth->fetchrow_array) {
    my $ar = Koha::WarehouseRequests->find($request[0]);
    $ar->complete();
}