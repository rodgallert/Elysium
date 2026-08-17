using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Prince.Data.Conversions;
using Prince.Domain.Models.Producers;

namespace Prince.Data.Configurations;

public class ProducerConfiguration : IEntityTypeConfiguration<Producer>
{
    public void Configure(EntityTypeBuilder<Producer> builder)
    {
        builder.ToTable("producers");
        builder.HasKey(p => p.Id);

        builder.Property(p => p.Name).IsRequired().HasMaxLength(200);

        builder.Property(p => p.Email).IsRequired().HasMaxLength(320);
        builder.HasIndex(p => p.Email).IsUnique();

        builder.Property(p => p.PasswordHash)
            .HasConversion(PasswordHashValueConverter.Instance)
            .IsRequired();

        builder.Property(p => p.Balance)
            .HasConversion(MoneyValueConverter.Instance)
            .HasColumnType("numeric(12,2)")
            .IsRequired();

        builder.Property(p => p.VerificationStatus)
            .HasConversion<string>()
            .HasMaxLength(20)
            .IsRequired();

        builder.Property(p => p.Cpf)
            .HasConversion(CpfValueConverter.NullableInstance)
            .HasMaxLength(11);
        builder.HasIndex(p => p.Cpf).IsUnique();

        builder.OwnsOne(p => p.Address, address =>
        {
            address.Property(a => a.Street).HasColumnName("address_street").HasMaxLength(200);
            address.Property(a => a.Number).HasColumnName("address_number").HasMaxLength(20);
            address.Property(a => a.Complement).HasColumnName("address_complement").HasMaxLength(200);
            address.Property(a => a.Neighborhood).HasColumnName("address_neighborhood").HasMaxLength(200);
            address.Property(a => a.City).HasColumnName("address_city").HasMaxLength(200);
            address.Property(a => a.State).HasColumnName("address_state").HasMaxLength(2);
            address.Property(a => a.PostalCode).HasColumnName("address_postal_code").HasMaxLength(8);
        });
    }
}
