using Prince.Domain.Models.Payments;

namespace Prince.Domain.Models.Products;

/// <summary>
/// A way to sell a Product — carries the price a buyer actually pays. A product can have
/// several offers (e.g. regular price vs. a promotional bundle); a Transaction references
/// the Offer that was purchased (by Id), not the Product directly, and snapshots this
/// offer's price at the moment of purchase since it can change later via UpdateDetails.
/// </summary>
public sealed class Offer
{
    public Guid Id { get; }
    public Guid ProductId { get; }
    public string Name { get; private set; } = null!;
    public Money RealPrice { get; private set; }
    public Money DiscountPrice { get; private set; }
    public string Description { get; private set; } = null!;

    // For EF Core materialization only — bypasses Id generation so reads don't mutate identity.
    private Offer() { }

    public Offer(Guid productId, string name, Money realPrice, Money discountPrice, string description)
    {
        Id = Guid.NewGuid();
        ProductId = productId;
        Name = ValidateName(name);
        Description = ValidateDescription(description);
        (RealPrice, DiscountPrice) = ValidatePrices(realPrice, discountPrice);
    }

    public void UpdateDetails(string name, Money realPrice, Money discountPrice, string description)
    {
        var validatedName = ValidateName(name);
        var validatedDescription = ValidateDescription(description);
        var (validatedRealPrice, validatedDiscountPrice) = ValidatePrices(realPrice, discountPrice);

        Name = validatedName;
        Description = validatedDescription;
        RealPrice = validatedRealPrice;
        DiscountPrice = validatedDiscountPrice;
    }

    private static string ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("Offer name is required.", nameof(name));
        }

        return name;
    }

    private static string ValidateDescription(string description)
    {
        if (string.IsNullOrWhiteSpace(description))
        {
            throw new ArgumentException("Offer description is required.", nameof(description));
        }

        return description;
    }

    private static (Money RealPrice, Money DiscountPrice) ValidatePrices(Money realPrice, Money discountPrice)
    {
        if (discountPrice > realPrice)
        {
            throw new ArgumentException(
                $"Discount price ({discountPrice}) cannot exceed the real price ({realPrice}).", nameof(discountPrice));
        }

        return (realPrice, discountPrice);
    }
}
