using Prince.Domain.Models.Payments;

namespace Prince.Domain.Tests.Payments;

public class WithdrawalTests
{
    [Fact]
    public void Withdrawal_DeductsGatewayFeeFromRequestedAmount()
    {
        var withdrawal = new Withdrawal(Guid.NewGuid(), Money.Brl(100m), PaymentGateway.PagarMe);

        Assert.Equal(Money.Brl(10m), withdrawal.GatewayFee);
        Assert.Equal(Money.Brl(90m), withdrawal.NetAmountPaidOut);
    }

    [Theory]
    [InlineData(10)]
    [InlineData(5)]
    public void Withdrawal_WithAmountNotExceedingGatewayFee_Throws(decimal requestedAmount)
    {
        Assert.Throws<InvalidOperationException>(() =>
            new Withdrawal(Guid.NewGuid(), Money.Brl(requestedAmount), PaymentGateway.MercadoPago));
    }

    [Fact]
    public void Withdrawal_RequestedAmountEqualsFeePlusNetPaidOut()
    {
        var withdrawal = new Withdrawal(Guid.NewGuid(), Money.Brl(347.50m), PaymentGateway.PagarMe);

        Assert.Equal(withdrawal.RequestedAmount, withdrawal.GatewayFee + withdrawal.NetAmountPaidOut);
    }
}
