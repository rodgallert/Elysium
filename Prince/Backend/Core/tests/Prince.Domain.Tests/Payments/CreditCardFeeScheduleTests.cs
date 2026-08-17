using Prince.Domain.Models.Payments;

namespace Prince.Domain.Tests.Payments;

public class CreditCardFeeScheduleTests
{
    [Fact]
    public void Pix_HasNoFee()
    {
        var fee = CreditCardFeeSchedule.Calculate(Money.Brl(100m), new PaymentMethod.Pix());

        Assert.Equal(Money.Zero, fee);
    }

    [Fact]
    public void Boleto_HasNoFee()
    {
        var fee = CreditCardFeeSchedule.Calculate(Money.Brl(100m), new PaymentMethod.Boleto());

        Assert.Equal(Money.Zero, fee);
    }

    [Fact]
    public void DebitCard_HasNoFee()
    {
        var fee = CreditCardFeeSchedule.Calculate(Money.Brl(100m), new PaymentMethod.DebitCard());

        Assert.Equal(Money.Zero, fee);
    }

    [Theory]
    [InlineData(1, 2.99)]
    [InlineData(2, 3.99)]
    [InlineData(6, 3.99)]
    [InlineData(7, 4.99)]
    [InlineData(12, 4.99)]
    public void CreditCard_FeeScalesWithInstallmentTier(int installments, decimal expectedFee)
    {
        var fee = CreditCardFeeSchedule.Calculate(Money.Brl(100m), new PaymentMethod.CreditCard(installments));

        Assert.Equal(expectedFee, fee.Amount);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(13)]
    public void CreditCard_WithInstallmentsOutOfRange_Throws(int installments)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new PaymentMethod.CreditCard(installments));
    }
}
