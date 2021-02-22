use utf8;
package Koha::Schema::Result::WarehouseRequest;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Koha::Schema::WarehouseRequests::Result::WarehouseRequest

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<warehouse_requests>

=cut

__PACKAGE__->table("warehouse_requests");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 borrowernumber

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 biblionumber

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 itemnumber

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

=head2 branchcode

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 10

=head2 volume

  data_type: 'text'
  is_nullable: 1

=head2 issue

  data_type: 'text'
  is_nullable: 1

=head2 date

  data_type: 'text'
  is_nullable: 1

=head2 patron_name

  data_type: 'text'
  is_nullable: 1

=head2 patron_notes

  data_type: 'text'
  is_nullable: 1

=head2 status

  data_type: 'enum'
  default_value: 'PENDING'
  extra: {list => ["PENDING","PROCESSING","WAITING","COMPLETED","CANCELED"]}
  is_nullable: 0

=head2 notes

  data_type: 'text'
  is_nullable: 1

=head2 created_on

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: current_timestamp
  is_nullable: 0

=head2 updated_on

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  is_nullable: 1

=head2 deadline

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  is_nullable: 1
  
=head2 gonenoaddress
  data_type: 'tinyint'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "borrowernumber",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "biblionumber",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "itemnumber",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
  "branchcode",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 10 },
  "volume",
  { data_type => "text", is_nullable => 1 },
  "issue",
  { data_type => "text", is_nullable => 1 },
  "date",
  { data_type => "text", is_nullable => 1 },
  "patron_name",
  { data_type => "text", is_nullable => 1 },
  "patron_notes",
  { data_type => "text", is_nullable => 1 },
  "status",
  {
    data_type => "enum",
    default_value => "PENDING",
    extra => {
      list => ["PENDING", "PROCESSING", "WAITING", "COMPLETED", "CANCELED"],
    },
    is_nullable => 0,
  },
  "notes",
  { data_type => "text", is_nullable => 1 },
  "created_on",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 0,
  },
  "updated_on",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "deadline",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "archived",
  { data_type => "tinyint", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 biblionumber

Type: belongs_to

Related object: L<Koha::Schema::WarehouseRequests::Result::Biblio>

=cut

__PACKAGE__->belongs_to(
  "biblionumber",
  "Koha::Schema::WarehouseRequests::Result::Biblio",
  { biblionumber => "biblionumber" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 borrowernumber

Type: belongs_to

Related object: L<Koha::Schema::WarehouseRequests::Result::Borrower>

=cut

__PACKAGE__->belongs_to(
  "borrowernumber",
  "Koha::Schema::WarehouseRequests::Result::Borrower",
  { borrowernumber => "borrowernumber" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 branchcode

Type: belongs_to

Related object: L<Koha::Schema::WarehouseRequests::Result::Branch>

=cut

__PACKAGE__->belongs_to(
  "branchcode",
  "Koha::Schema::WarehouseRequests::Result::Branch",
  { branchcode => "branchcode" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "SET NULL",
    on_update     => "CASCADE",
  },
);

=head2 itemnumber

Type: belongs_to

Related object: L<Koha::Schema::WarehouseRequests::Result::Item>

=cut

__PACKAGE__->belongs_to(
  "itemnumber",
  "Koha::Schema::WarehouseRequests::Result::Item",
  { itemnumber => "itemnumber" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "SET NULL",
    on_update     => "CASCADE",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07046 @ 2019-07-08 13:18:08
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:fCsI/NXPvFHf9SpcWMtdYQ

__PACKAGE__->add_columns(
    '+archived' => { is_boolean => 1 }
);

1;
