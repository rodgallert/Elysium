using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Prince.Data.Conversions;
using Prince.Domain.Models.Products;

namespace Prince.Data.Configurations;

public class OfferConfiguration : IEntityTypeConfiguration<Offer>
{
    public void Configure(EntityTypeBuilder<Offer> builder)
    {
        builder.ToTable("offers");
        builder.HasKey(o => o.Id);

        builder.Property(o => o.ProductId).IsRequired();
        builder.HasIndex(o => o.ProductId);

        builder.Property(o => o.Name).IsRequired().HasMaxLength(200);
        builder.Property(o => o.Description).IsRequired();

        builder.Property(o => o.RealPrice)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(o => o.DiscountPrice)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();
    }
}
