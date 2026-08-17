using Prince.Domain.Models.Payments;
using Prince.Domain.Models.Products;

namespace Prince.Domain.Tests.Products;

public class OfferTests
{
    private static Offer NewOffer() => new(
        Guid.NewGuid(),
        "Black Friday Bundle",
        Money.Brl(200m),
        Money.Brl(149.90m),
        "Get the full course plus bonus material.");

    [Fact]
    public void Constructor_WithValidFields_Succeeds()
    {
        var offer = NewOffer();

        Assert.Equal(Money.Brl(200m), offer.RealPrice);
        Assert.Equal(Money.Brl(149.90m), offer.DiscountPrice);
    }

    [Fact]
    public void Constructor_WithDiscountPriceEqualToRealPrice_Succeeds()
    {
        var offer = new Offer(Guid.NewGuid(), "Regular Price", Money.Brl(100m), Money.Brl(100m), "No discount right now.");

        Assert.Equal(offer.RealPrice, offer.DiscountPrice);
    }

    [Fact]
    public void Constructor_WithDiscountPriceAboveRealPrice_Throws()
    {
        Assert.Throws<ArgumentException>(() =>
            new Offer(Guid.NewGuid(), "Broken Offer", Money.Brl(100m), Money.Brl(150m), "desc"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Constructor_WithBlankName_Throws(string name)
    {
        Assert.Throws<ArgumentException>(() =>
            new Offer(Guid.NewGuid(), name, Money.Brl(100m), Money.Brl(100m), "desc"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Constructor_WithBlankDescription_Throws(string description)
    {
        Assert.Throws<ArgumentException>(() =>
            new Offer(Guid.NewGuid(), "name", Money.Brl(100m), Money.Brl(100m), description));
    }

    [Fact]
    public void UpdateDetails_ChangesNamePricesAndDescription()
    {
        var offer = NewOffer();

        offer.UpdateDetails("New Name", Money.Brl(300m), Money.Brl(250m), "New description.");

        Assert.Equal("New Name", offer.Name);
        Assert.Equal(Money.Brl(300m), offer.RealPrice);
        Assert.Equal(Money.Brl(250m), offer.DiscountPrice);
        Assert.Equal("New description.", offer.Description);
    }

    [Fact]
    public void UpdateDetails_WithDiscountPriceAboveRealPrice_ThrowsAndLeavesOfferUnchanged()
    {
        var offer = NewOffer();

        Assert.Throws<ArgumentException>(() =>
            offer.UpdateDetails("New Name", Money.Brl(100m), Money.Brl(150m), "desc"));

        Assert.Equal(Money.Brl(200m), offer.RealPrice);
        Assert.Equal(Money.Brl(149.90m), offer.DiscountPrice);
    }
}
