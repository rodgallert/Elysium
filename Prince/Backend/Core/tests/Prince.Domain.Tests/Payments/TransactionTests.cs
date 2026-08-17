using Prince.Domain.Models.Payments;
using Prince.Domain.Models.Shared;

namespace Prince.Domain.Tests.Payments;

public class TransactionTests
{
    private static Buyer NewBuyer() => new("John Buyer", Cpf.Parse("111.444.777-35"), "john@buyer.local");

    [Fact]
    public void PixTransaction_ProducerReceivesFullAmountPaid()
    {
        var transaction = new Transaction(Guid.NewGuid(), Guid.NewGuid(), NewBuyer(), Money.Brl(100m), new PaymentMethod.Pix());

        Assert.Equal(Money.Zero, transaction.PlatformFee);
        Assert.Equal(Money.Brl(100m), transaction.ProducerNetAmount);
    }

    [Fact]
    public void CreditCardTransaction_PlatformFeeIsDeductedFromProducerPayout()
    {
        var transaction = new Transaction(Guid.NewGuid(), Guid.NewGuid(), NewBuyer(), Money.Brl(100m), new PaymentMethod.CreditCard(3));

        Assert.Equal(Money.Brl(3.99m), transaction.PlatformFee);
        Assert.Equal(Money.Brl(96.01m), transaction.ProducerNetAmount);
    }

    [Fact]
    public void CreditCardTransaction_AmountPaidEqualsPlatformFeePlusProducerNetAmount()
    {
        var transaction = new Transaction(Guid.NewGuid(), Guid.NewGuid(), NewBuyer(), Money.Brl(250m), new PaymentMethod.CreditCard(10));

        Assert.Equal(transaction.AmountPaid, transaction.PlatformFee + transaction.ProducerNetAmount);
    }

    [Fact]
    public void Transaction_CarriesTheOfferIdAndBuyer()
    {
        var offerId = Guid.NewGuid();
        var buyer = NewBuyer();

        var transaction = new Transaction(Guid.NewGuid(), offerId, buyer, Money.Brl(50m), new PaymentMethod.Pix());

        Assert.Equal(offerId, transaction.OfferId);
        Assert.Equal(buyer, transaction.Buyer);
    }
}
