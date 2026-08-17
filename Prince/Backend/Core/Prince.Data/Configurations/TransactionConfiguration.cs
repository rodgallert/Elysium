using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Prince.Data.Conversions;
using Prince.Domain.Models.Payments;

namespace Prince.Data.Configurations;

public class TransactionConfiguration : IEntityTypeConfiguration<Transaction>
{
    public void Configure(EntityTypeBuilder<Transaction> builder)
    {
        builder.ToTable("transactions");
        builder.HasKey(t => t.Id);

        builder.Property(t => t.ProducerId).IsRequired();
        builder.HasIndex(t => t.ProducerId);

        builder.Property(t => t.OfferId).IsRequired();
        builder.HasIndex(t => t.OfferId);

        builder.Property(t => t.AmountPaid)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(t => t.PlatformFee)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(t => t.ProducerNetAmount)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(t => t.PaymentMethod)
            .HasConversion(PaymentMethodValueConverter.Instance)
            .IsRequired();

        builder.OwnsOne(t => t.Buyer, buyer =>
        {
            buyer.Property(b => b.Name).HasColumnName("buyer_name").IsRequired().HasMaxLength(200);
            buyer.Property(b => b.Email).HasColumnName("buyer_email").IsRequired().HasMaxLength(320);
            buyer.Property(b => b.Cpf)
                .HasConversion(CpfValueConverter.Instance)
                .HasColumnName("buyer_cpf")
                .HasMaxLength(11)
                .IsRequired();
        });
    }
}
