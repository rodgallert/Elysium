using Prince.Domain.Models.Payments;
using Prince.Domain.Models.Producers;
using Prince.Domain.Models.Shared;

namespace Prince.Domain.Tests.Producers;

public class ProducerTests
{
    private static Address ValidAddress() => new(
        street: "Rua das Flores",
        number: "123",
        complement: "Apto 45",
        neighborhood: "Centro",
        city: "São Paulo",
        state: "SP",
        postalCode: "01310-100");

    private static Cpf ValidCpf() => Cpf.Parse("111.444.777-35");

    private static Buyer NewBuyer() => new("John Buyer", Cpf.Parse("529.982.247-25"), "john@buyer.local");

    private static Producer NewProducer() => new("Ada Lovelace", "ada@prince.local", "correct-horse-battery");

    [Fact]
    public void NewProducer_StartsWithZeroBalancePendingVerificationAndNoAddress()
    {
        var producer = NewProducer();

        Assert.Equal(Money.Zero, producer.Balance);
        Assert.Equal(ProducerVerificationStatus.Pending, producer.VerificationStatus);
        Assert.Null(producer.Cpf);
        Assert.Null(producer.Address);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Constructor_WithBlankName_Throws(string name)
    {
        Assert.Throws<ArgumentException>(() => new Producer(name, "ada@prince.local", "correct-horse-battery"));
    }

    [Fact]
    public void UpdateAddress_SetsAddress()
    {
        var producer = NewProducer();

        producer.UpdateAddress(ValidAddress());

        Assert.Equal(ValidAddress(), producer.Address);
    }

    [Fact]
    public void RecordTransaction_CreditsBalanceWithProducerNetAmount()
    {
        var producer = NewProducer();

        var transaction = producer.RecordTransaction(Guid.NewGuid(), Money.Brl(100m), NewBuyer(), new PaymentMethod.CreditCard(3));

        Assert.Equal(Money.Brl(96.01m), transaction.ProducerNetAmount);
        Assert.Equal(Money.Brl(96.01m), producer.Balance);
    }

    [Fact]
    public void RecordTransaction_CanBeCalledBeforeCpfIsRegistered()
    {
        var producer = NewProducer();

        var transaction = producer.RecordTransaction(Guid.NewGuid(), Money.Brl(50m), NewBuyer(), new PaymentMethod.Pix());

        Assert.Equal(ProducerVerificationStatus.Pending, producer.VerificationStatus);
        Assert.Equal(Money.Brl(50m), transaction.ProducerNetAmount);
    }

    [Fact]
    public void RequestWithdrawal_WithoutCpfRegistered_Throws()
    {
        var producer = NewProducer();
        producer.RecordTransaction(Guid.NewGuid(), Money.Brl(100m), NewBuyer(), new PaymentMethod.Pix());

        Assert.Throws<InvalidOperationException>(() =>
            producer.RequestWithdrawal(Money.Brl(50m), PaymentGateway.PagarMe));
    }

    [Fact]
    public void RequestWithdrawal_ExceedingBalance_Throws()
    {
        var producer = NewProducer();
        producer.RecordTransaction(Guid.NewGuid(), Money.Brl(20m), NewBuyer(), new PaymentMethod.Pix());
        producer.RegisterCpf(ValidCpf());

        Assert.Throws<InvalidOperationException>(() =>
            producer.RequestWithdrawal(Money.Brl(50m), PaymentGateway.PagarMe));
    }

    [Fact]
    public void RequestWithdrawal_AfterCpfRegisteredWithSufficientBalance_DeductsFromBalance()
    {
        var producer = NewProducer();
        producer.RecordTransaction(Guid.NewGuid(), Money.Brl(200m), NewBuyer(), new PaymentMethod.Pix());
        producer.RegisterCpf(ValidCpf());

        var withdrawal = producer.RequestWithdrawal(Money.Brl(100m), PaymentGateway.PagarMe);

        Assert.Equal(Money.Brl(90m), withdrawal.NetAmountPaidOut);
        Assert.Equal(Money.Brl(100m), producer.Balance);
    }

    [Fact]
    public void Authenticate_WithCorrectPassword_ReturnsTrue()
    {
        var producer = NewProducer();

        Assert.True(producer.Authenticate("correct-horse-battery"));
    }

    [Fact]
    public void Authenticate_WithWrongPassword_ReturnsFalse()
    {
        var producer = NewProducer();

        Assert.False(producer.Authenticate("wrong-password"));
    }

    [Fact]
    public void ChangePassword_InvalidatesOldPassword()
    {
        var producer = NewProducer();

        producer.ChangePassword("new-correct-password");

        Assert.False(producer.Authenticate("correct-horse-battery"));
        Assert.True(producer.Authenticate("new-correct-password"));
    }
}
