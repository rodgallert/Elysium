namespace Prince.Domain.Models.Products;

public enum ProductStatus
{
    Active,
    Blocked,
    Deleted
}

/// <summary>
/// Something a producer sells — a downloadable file, access to a content platform, or a
/// course. Starts Active on creation (no approval queue, consistent with the platform's
/// fast-to-start-selling philosophy) and stays that way until blocked or deleted. Deleted
/// is terminal — a deleted product can never be reactivated or blocked again.
/// </summary>
public sealed class Product
{
    private const int MaxNameLength = 200;
    private const int MaxShortDescriptionLength = 500;

    public Guid Id { get; }
    public Guid ProducerId { get; }
    public string Name { get; private set; } = null!;
    public string ShortDescription { get; private set; } = null!;
    public string ImageUrl { get; private set; } = null!;
    public ProductType Type { get; } = null!;
    public ProductStatus Status { get; private set; }

    // For EF Core materialization only — bypasses Id generation so reads don't mutate identity.
    private Product() { }

    public Product(Guid producerId, string name, string shortDescription, string imageUrl, ProductType type)
    {
        Id = Guid.NewGuid();
        ProducerId = producerId;
        Name = ValidateName(name);
        ShortDescription = ValidateShortDescription(shortDescription);
        ImageUrl = ValidateImageUrl(imageUrl);
        Type = type ?? throw new ArgumentNullException(nameof(type));
        Status = ProductStatus.Active;
    }

    public void UpdateDetails(string name, string shortDescription, string imageUrl)
    {
        var validatedName = ValidateName(name);
        var validatedShortDescription = ValidateShortDescription(shortDescription);
        var validatedImageUrl = ValidateImageUrl(imageUrl);

        Name = validatedName;
        ShortDescription = validatedShortDescription;
        ImageUrl = validatedImageUrl;
    }

    public void Activate()
    {
        if (Status == ProductStatus.Deleted)
        {
            throw new InvalidOperationException("A deleted product cannot be reactivated.");
        }

        Status = ProductStatus.Active;
    }

    public void Block()
    {
        if (Status == ProductStatus.Deleted)
        {
            throw new InvalidOperationException("A deleted product cannot be blocked.");
        }

        Status = ProductStatus.Blocked;
    }

    public void Delete() => Status = ProductStatus.Deleted;

    private static string ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("Product name is required.", nameof(name));
        }

        if (name.Length > MaxNameLength)
        {
            throw new ArgumentException($"Product name cannot exceed {MaxNameLength} characters.", nameof(name));
        }

        return name;
    }

    private static string ValidateShortDescription(string shortDescription)
    {
        if (string.IsNullOrWhiteSpace(shortDescription))
        {
            throw new ArgumentException("Product short description is required.", nameof(shortDescription));
        }

        if (shortDescription.Length > MaxShortDescriptionLength)
        {
            throw new ArgumentException($"Short description cannot exceed {MaxShortDescriptionLength} characters.", nameof(shortDescription));
        }

        return shortDescription;
    }

    private static string ValidateImageUrl(string imageUrl)
    {
        var isValid = Uri.TryCreate(imageUrl, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);

        if (!isValid)
        {
            throw new ArgumentException($"'{imageUrl}' is not a valid image URL.", nameof(imageUrl));
        }

        return imageUrl;
    }
}
