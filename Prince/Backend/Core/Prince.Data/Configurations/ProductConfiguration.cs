using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Prince.Data.Conversions;
using Prince.Domain.Models.Products;

namespace Prince.Data.Configurations;

public class ProductConfiguration : IEntityTypeConfiguration<Product>
{
    public void Configure(EntityTypeBuilder<Product> builder)
    {
        builder.ToTable("products");
        builder.HasKey(p => p.Id);

        builder.Property(p => p.ProducerId).IsRequired();
        builder.HasIndex(p => p.ProducerId);

        builder.Property(p => p.Name).IsRequired().HasMaxLength(200);

        builder.Property(p => p.ShortDescription).IsRequired().HasMaxLength(500);

        builder.Property(p => p.ImageUrl).IsRequired();

        builder.Property(p => p.Type)
            .HasConversion(ProductTypeValueConverter.Instance)
            .HasColumnType("jsonb")
            .IsRequired();

        builder.Property(p => p.Status)
            .HasConversion<string>()
            .HasMaxLength(20)
            .IsRequired();
    }
}
