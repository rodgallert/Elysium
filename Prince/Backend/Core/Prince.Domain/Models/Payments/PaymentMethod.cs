namespace Prince.Domain.Models.Payments;

/// <summary>How a buyer paid for a sale. Closed set of variants — see CreditCardFeeSchedule for how each is priced.</summary>
public abstract record PaymentMethod
{
    public sealed record Pix : PaymentMethod;

    public sealed record Boleto : PaymentMethod;

    public sealed record DebitCard : PaymentMethod;

    public sealed record CreditCard : PaymentMethod
    {
        public int Installments { get; }

        public CreditCard(int installments)
        {
            if (installments is < 1 or > 12)
            {
                throw new ArgumentOutOfRangeException(nameof(installments), "Credit card installments must be between 1 and 12.");
            }

            Installments = installments;
        }
    }
}
