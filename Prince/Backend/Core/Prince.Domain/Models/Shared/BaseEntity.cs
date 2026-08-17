namespace Prince.Domain.Models.Shared;

/// <summary>
/// Common base for entities managed through IRepository&lt;T&gt; — the one field every entity
/// in this domain actually duplicates. Id is database-generated (see PrinceDbContext, which
/// configures every BaseEntity-derived type's Id column with a `gen_random_uuid()` default) —
/// entity constructors no longer assign it themselves. A newly-constructed entity's Id is
/// Guid.Empty until it's actually persisted; only after SaveChanges does the real value exist.
/// </summary>
public abstract class BaseEntity
{
    public Guid Id { get; protected set; }
}
