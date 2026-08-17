using Prince.Domain.Models.Products;

namespace Prince.Domain.Tests.Products;

public class ProductFileTests
{
    private static ProductFile ValidFile() => new(
        storageKey: "producers/abc123/products/def456/ebook.pdf",
        fileName: "ebook.pdf",
        sizeInBytes: 2_048_000,
        contentType: "application/pdf");

    [Fact]
    public void Constructor_WithValidFields_Succeeds()
    {
        var file = ValidFile();

        Assert.Equal("ebook.pdf", file.FileName);
        Assert.Equal(2_048_000, file.SizeInBytes);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Constructor_WithBlankStorageKey_Throws(string storageKey)
    {
        Assert.Throws<ArgumentException>(() => new ProductFile(storageKey, "ebook.pdf", 100, "application/pdf"));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void Constructor_WithNonPositiveSize_Throws(long size)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new ProductFile("key", "ebook.pdf", size, "application/pdf"));
    }

    [Fact]
    public void Constructor_WithBlankContentType_Throws()
    {
        Assert.Throws<ArgumentException>(() => new ProductFile("key", "ebook.pdf", 100, ""));
    }

    [Fact]
    public void DigitalDownload_CarriesTheFile()
    {
        var file = ValidFile();

        var type = new ProductType.DigitalDownload(file);

        Assert.Equal(file, type.File);
    }
}
