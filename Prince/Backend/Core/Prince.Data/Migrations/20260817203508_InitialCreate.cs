using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Prince.Data.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "offers",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    product_id = table.Column<Guid>(type: "uuid", nullable: false),
                    name = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    real_price = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    discount_price = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    description = table.Column<string>(type: "text", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_offers", x => x.id);
                });

            migrationBuilder.CreateTable(
                name: "producers",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    name = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    email = table.Column<string>(type: "character varying(320)", maxLength: 320, nullable: false),
                    password_hash = table.Column<string>(type: "text", nullable: false),
                    address_street = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: true),
                    address_number = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: true),
                    address_complement = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: true),
                    address_neighborhood = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: true),
                    address_city = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: true),
                    address_state = table.Column<string>(type: "character varying(2)", maxLength: 2, nullable: true),
                    address_postal_code = table.Column<string>(type: "character varying(8)", maxLength: 8, nullable: true),
                    balance = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    verification_status = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    cpf = table.Column<string>(type: "character varying(11)", maxLength: 11, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_producers", x => x.id);
                });

            migrationBuilder.CreateTable(
                name: "products",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    producer_id = table.Column<Guid>(type: "uuid", nullable: false),
                    name = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    short_description = table.Column<string>(type: "character varying(500)", maxLength: 500, nullable: false),
                    image_url = table.Column<string>(type: "text", nullable: false),
                    type = table.Column<string>(type: "jsonb", nullable: false),
                    status = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_products", x => x.id);
                });

            migrationBuilder.CreateTable(
                name: "transactions",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    producer_id = table.Column<Guid>(type: "uuid", nullable: false),
                    offer_id = table.Column<Guid>(type: "uuid", nullable: false),
                    buyer_name = table.Column<string>(type: "character varying(200)", maxLength: 200, nullable: false),
                    buyer_cpf = table.Column<string>(type: "character varying(11)", maxLength: 11, nullable: false),
                    buyer_email = table.Column<string>(type: "character varying(320)", maxLength: 320, nullable: false),
                    amount_paid = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    payment_method = table.Column<string>(type: "text", nullable: false),
                    platform_fee = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    producer_net_amount = table.Column<decimal>(type: "numeric(12,2)", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_transactions", x => x.id);
                });

            migrationBuilder.CreateTable(
                name: "withdrawals",
                columns: table => new
                {
                    id = table.Column<Guid>(type: "uuid", nullable: false),
                    producer_id = table.Column<Guid>(type: "uuid", nullable: false),
                    requested_amount = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    gateway = table.Column<string>(type: "character varying(20)", maxLength: 20, nullable: false),
                    gateway_fee = table.Column<decimal>(type: "numeric(12,2)", nullable: false),
                    net_amount_paid_out = table.Column<decimal>(type: "numeric(12,2)", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("pk_withdrawals", x => x.id);
                });

            migrationBuilder.CreateIndex(
                name: "ix_offers_product_id",
                table: "offers",
                column: "product_id");

            migrationBuilder.CreateIndex(
                name: "ix_producers_cpf",
                table: "producers",
                column: "cpf",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_producers_email",
                table: "producers",
                column: "email",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_products_producer_id",
                table: "products",
                column: "producer_id");

            migrationBuilder.CreateIndex(
                name: "ix_transactions_offer_id",
                table: "transactions",
                column: "offer_id");

            migrationBuilder.CreateIndex(
                name: "ix_transactions_producer_id",
                table: "transactions",
                column: "producer_id");

            migrationBuilder.CreateIndex(
                name: "ix_withdrawals_producer_id",
                table: "withdrawals",
                column: "producer_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "offers");

            migrationBuilder.DropTable(
                name: "producers");

            migrationBuilder.DropTable(
                name: "products");

            migrationBuilder.DropTable(
                name: "transactions");

            migrationBuilder.DropTable(
                name: "withdrawals");
        }
    }
}
