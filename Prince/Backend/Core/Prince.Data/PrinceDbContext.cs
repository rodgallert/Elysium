using Microsoft.EntityFrameworkCore;
using Prince.Domain.Models.Payments;
using Prince.Domain.Models.Producers;
using Prince.Domain.Models.Products;

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
    }
}
