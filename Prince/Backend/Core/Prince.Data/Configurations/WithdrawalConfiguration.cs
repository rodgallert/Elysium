using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Prince.Data.Conversions;
using Prince.Domain.Models.Payments;

namespace Prince.Data.Configurations;

public class WithdrawalConfiguration : IEntityTypeConfiguration<Withdrawal>
{
    public void Configure(EntityTypeBuilder<Withdrawal> builder)
    {
        builder.ToTable("withdrawals");
        builder.HasKey(w => w.Id);

        builder.Property(w => w.ProducerId).IsRequired();
        builder.HasIndex(w => w.ProducerId);

        builder.Property(w => w.RequestedAmount)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(w => w.GatewayFee)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(w => w.NetAmountPaidOut)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(w => w.Gateway)
            .HasConversion<string>()
            .HasMaxLength(20)
            .IsRequired();
    }
}
