using Microsoft.EntityFrameworkCore;
using Prince.Domain.Models.Payments;
using Prince.Domain.Models.Producers;
using Prince.Domain.Models.Products;
using Prince.Domain.Models.Shared;

namespace Prince.Data;

public class PrinceDbContext(DbContextOptions<PrinceDbContext> options) : DbContext(options)
{
    public DbSet<Producer> Producers => Set<Producer>();
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Offer> Offers => Set<Offer>();
    public DbSet<Transaction> Transactions => Set<Transaction>();
    public DbSet<Withdrawal> Withdrawals => Set<Withdrawal>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(PrinceDbContext).Assembly);

        // Every BaseEntity-derived type gets a database-generated Id — one place to configure
        // it rather than repeating HasDefaultValueSql in each entity's IEntityTypeConfiguration.
        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            if (typeof(BaseEntity).IsAssignableFrom(entityType.ClrType))
            {
                modelBuilder.Entity(entityType.ClrType)
                    .Property(nameof(BaseEntity.Id))
                    .HasDefaultValueSql("gen_random_uuid()");
            }
        }
    }
}
