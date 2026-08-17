using Prince.Domain.Models.Shared;

namespace Prince.Domain.Tests.Shared;

public class CpfTests
{
    [Theory]
    [InlineData("111.444.777-35")]
    [InlineData("11144477735")]
    public void Parse_WithValidCpf_Succeeds(string input)
    {
        var cpf = Cpf.Parse(input);

        Assert.Equal("11144477735", cpf.Digits);
    }

    [Fact]
    public void ToString_FormatsWithDotsAndDash()
    {
        var cpf = Cpf.Parse("11144477735");

        Assert.Equal("111.444.777-35", cpf.ToString());
    }

    [Fact]
    public void Parse_WithWrongCheckDigits_Throws()
    {
        Assert.Throws<ArgumentException>(() => Cpf.Parse("111.444.777-36"));
    }

    [Fact]
    public void Parse_WithAllRepeatedDigits_Throws()
    {
        Assert.Throws<ArgumentException>(() => Cpf.Parse("111.111.111-11"));
    }

    [Theory]
    [InlineData("123")]
    [InlineData("")]
    [InlineData("111.444.777-350")]
    public void Parse_WithWrongLength_Throws(string input)
    {
        Assert.Throws<ArgumentException>(() => Cpf.Parse(input));
    }
}
