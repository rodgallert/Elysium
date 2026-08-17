using Prince.Domain.Models.Products;

namespace Prince.Domain.Tests.Products;

public class ProductTests
{
    private static Product NewProduct() => new(
        Guid.NewGuid(),
        "Advanced C# Course",
        "Everything you need to master C#.",
        "https://cdn.prince.local/images/advanced-csharp.png",
        new ProductType.Course());

    [Fact]
    public void NewProduct_StartsActive()
    {
        var product = NewProduct();

        Assert.Equal(ProductStatus.Active, product.Status);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Constructor_WithBlankName_Throws(string name)
    {
        Assert.Throws<ArgumentException>(() => new Product(
            Guid.NewGuid(), name, "desc", "https://cdn.prince.local/img.png", new ProductType.Course()));
    }

    [Fact]
    public void Constructor_WithNameTooLong_Throws()
    {
        var tooLong = new string('a', 201);

        Assert.Throws<ArgumentException>(() => new Product(
            Guid.NewGuid(), tooLong, "desc", "https://cdn.prince.local/img.png", new ProductType.Course()));
    }

    [Fact]
    public void Constructor_WithShortDescriptionTooLong_Throws()
    {
        var tooLong = new string('a', 501);

        Assert.Throws<ArgumentException>(() => new Product(
            Guid.NewGuid(), "name", tooLong, "https://cdn.prince.local/img.png", new ProductType.Course()));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-a-url")]
    [InlineData("/relative/path.png")]
    public void Constructor_WithInvalidImageUrl_Throws(string imageUrl)
    {
        Assert.Throws<ArgumentException>(() => new Product(
            Guid.NewGuid(), "name", "desc", imageUrl, new ProductType.Course()));
    }

    [Fact]
    public void UpdateDetails_ChangesNameDescriptionAndImage()
    {
        var product = NewProduct();

        product.UpdateDetails("New Name", "New description.", "https://cdn.prince.local/images/new.png");

        Assert.Equal("New Name", product.Name);
        Assert.Equal("New description.", product.ShortDescription);
        Assert.Equal("https://cdn.prince.local/images/new.png", product.ImageUrl);
    }

    [Fact]
    public void UpdateDetails_WithInvalidImageUrl_ThrowsAndLeavesProductUnchanged()
    {
        var product = NewProduct();

        Assert.Throws<ArgumentException>(() =>
            product.UpdateDetails("New Name", "New description.", "not-a-url"));

        Assert.Equal("Advanced C# Course", product.Name);
        Assert.Equal("Everything you need to master C#.", product.ShortDescription);
    }

    [Fact]
    public void Block_TransitionsFromActiveToBlocked()
    {
        var product = NewProduct();

        product.Block();

        Assert.Equal(ProductStatus.Blocked, product.Status);
    }

    [Fact]
    public void Activate_TransitionsFromBlockedToActive()
    {
        var product = NewProduct();
        product.Block();

        product.Activate();

        Assert.Equal(ProductStatus.Active, product.Status);
    }

    [Fact]
    public void Delete_IsTerminal_BlockAfterDeleteThrows()
    {
        var product = NewProduct();
        product.Delete();

        Assert.Equal(ProductStatus.Deleted, product.Status);
        Assert.Throws<InvalidOperationException>(product.Block);
    }

    [Fact]
    public void Delete_IsTerminal_ActivateAfterDeleteThrows()
    {
        var product = NewProduct();
        product.Delete();

        Assert.Throws<InvalidOperationException>(product.Activate);
    }
}
