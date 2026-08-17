using Prince.Domain.Models.Producers;

namespace Prince.Domain.Tests.Producers;

public class AddressTests
{
    private static Address ValidAddress(string state = "SP", string postalCode = "01310-100") => new(
        street: "Rua das Flores",
        number: "123",
        complement: "Apto 45",
        neighborhood: "Centro",
        city: "São Paulo",
        state: state,
        postalCode: postalCode);

    [Fact]
    public void Constructor_WithValidFields_NormalizesStateAndPostalCode()
    {
        var address = ValidAddress(state: "sp", postalCode: "01310-100");

        Assert.Equal("SP", address.State);
        Assert.Equal("01310100", address.PostalCode);
    }

    [Fact]
    public void Constructor_WithInvalidStateCode_Throws()
    {
        Assert.Throws<ArgumentException>(() => ValidAddress(state: "XX"));
    }

    [Theory]
    [InlineData("123")]
    [InlineData("013101000")]
    [InlineData("")]
    public void Constructor_WithInvalidPostalCode_Throws(string postalCode)
    {
        Assert.Throws<ArgumentException>(() => ValidAddress(postalCode: postalCode));
    }

    [Fact]
    public void ToString_FormatsFullAddress()
    {
        var address = ValidAddress();

        Assert.Equal("Rua das Flores, 123 - Apto 45, Centro, São Paulo/SP, 01310-100", address.ToString());
    }

    [Fact]
    public void TwoAddressesWithSameValues_AreEqual()
    {
        Assert.Equal(ValidAddress(), ValidAddress());
    }
}
