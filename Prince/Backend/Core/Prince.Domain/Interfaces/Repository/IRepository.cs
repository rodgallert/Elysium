using Prince.Domain.Models.Shared;

namespace Prince.Domain.Interfaces.Repository;

/// <summary>
/// Basic persistence contract every repository implements. Entity-specific repositories
/// (e.g. IProducerRepository) inherit this and add their own queries on top.
/// </summary>
public interface IRepository<T> where T : BaseEntity
{
    Task<T?> GetAsync(Guid id, CancellationToken cancellationToken = default);

    Task<IReadOnlyList<T>> ListAsync(CancellationToken cancellationToken = default);

    Task AddAsync(T entity, CancellationToken cancellationToken = default);

    Task UpdateAsync(T entity, CancellationToken cancellationToken = default);

    Task DeleteAsync(T entity, CancellationToken cancellationToken = default);
}
