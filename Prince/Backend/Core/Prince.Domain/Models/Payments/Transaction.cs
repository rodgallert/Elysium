namespace Prince.Domain.Models.Payments;

/// <summary>
/// A single buyer's purchase of an offer. Splits the amount paid into what the platform keeps
/// (PlatformFee — company revenue) and what the producer is credited (ProducerNetAmount).
/// AmountPaid is a snapshot of the offer's price at the moment of purchase, passed in by the
/// caller rather than read live off the Offer — offer pricing can change later
/// (Offer.UpdateDetails), but a completed transaction must not retroactively change with it.
/// Only constructible via <see cref="Producers.Producer.RecordTransaction"/> — the producer's
/// balance must never drift out of sync with the transactions that funded it.
/// </summary>
public sealed class Transaction
{
    public Guid Id { get; }
    public Guid ProducerId { get; }
    public Guid OfferId { get; }
    public Buyer Buyer { get; } = null!;
    public Money AmountPaid { get; }
    public PaymentMethod PaymentMethod { get; } = null!;
    public Money PlatformFee { get; }
    public Money ProducerNetAmount { get; }

    // For EF Core materialization only — bypasses Id generation so reads don't mutate identity.
    private Transaction() { }

    internal Transaction(Guid producerId, Guid offerId, Buyer buyer, Money amountPaid, PaymentMethod paymentMethod)
    {
        Id = Guid.NewGuid();
        ProducerId = producerId;
        OfferId = offerId;
        Buyer = buyer;
        AmountPaid = amountPaid;
        PaymentMethod = paymentMethod;
        PlatformFee = CreditCardFeeSchedule.Calculate(amountPaid, paymentMethod);
        ProducerNetAmount = amountPaid - PlatformFee;
    }
}
