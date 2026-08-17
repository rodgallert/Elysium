namespace Prince.Domain.Models.Products;

/// <summary>What a buyer gets after purchasing. Closed set of variants.</summary>
public abstract record ProductType
{
    public sealed record DigitalDownload(ProductFile File) : ProductType;

    public sealed record ContentPlatformAccess : ProductType;

    public sealed record Course : ProductType;
}
