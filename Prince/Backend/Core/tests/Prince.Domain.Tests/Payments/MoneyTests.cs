using Prince.Domain.Models.Payments;

namespace Prince.Domain.Tests.Payments;

public class MoneyTests
{
    [Fact]
    public void Brl_WithNegativeAmount_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => Money.Brl(-0.01m));
    }

    [Fact]
    public void Subtraction_ResultingInNegative_Throws()
    {
        var small = Money.Brl(5m);
        var large = Money.Brl(10m);

        Assert.Throws<ArgumentOutOfRangeException>(() => small - large);
    }

    [Fact]
    public void Percentage_RoundsToTwoDecimalPlaces()
    {
        var amount = Money.Brl(100m);

        var fee = amount.Percentage(0.0399m);

        Assert.Equal(3.99m, fee.Amount);
    }

    [Theory]
    [InlineData(10, 5, true)]
    [InlineData(5, 10, false)]
    [InlineData(10, 10, false)]
    public void GreaterThan_ComparesAmounts(decimal left, decimal right, bool expected)
    {
        Assert.Equal(expected, Money.Brl(left) > Money.Brl(right));
    }
}
