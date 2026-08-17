namespace Prince.Domain.Models.Payments;

/// <summary>
/// A producer cashing out their accumulated balance through a payment gateway. The gateway's
/// withdrawal fee is a pass-through cost (not company revenue, see PaymentGatewayFees) deducted
/// from the requested amount before it lands in the producer's bank account.
/// Only constructible via <see cref="Producers.Producer.RequestWithdrawal"/> — verification and
/// available-balance checks must never be bypassable by constructing this directly.
/// </summary>
public sealed class Withdrawal
{
    public Guid Id { get; }
    public Guid ProducerId { get; }
    public Money RequestedAmount { get; }
    public PaymentGateway Gateway { get; }
    public Money GatewayFee { get; }
    public Money NetAmountPaidOut { get; }

    // For EF Core materialization only — bypasses Id generation so reads don't mutate identity.
    private Withdrawal() { }

    internal Withdrawal(Guid producerId, Money requestedAmount, PaymentGateway gateway)
    {
        var fee = PaymentGatewayFees.WithdrawalFeeFor(gateway);
        if (requestedAmount <= fee)
        {
            throw new InvalidOperationException(
                $"Withdrawal amount ({requestedAmount}) must exceed the gateway's withdrawal fee ({fee}).");
        }

        Id = Guid.NewGuid();
        ProducerId = producerId;
        RequestedAmount = requestedAmount;
        Gateway = gateway;
        GatewayFee = fee;
        NetAmountPaidOut = requestedAmount - fee;
    }
}
