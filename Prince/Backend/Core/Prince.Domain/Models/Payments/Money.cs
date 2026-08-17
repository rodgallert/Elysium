namespace Prince.Domain.Models.Payments;

/// <summary>Brazilian Real amount. Never negative — arithmetic that would go negative throws.</summary>
public readonly record struct Money
{
    public decimal Amount { get; }

    private Money(decimal amount)
    {
        if (amount < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(amount), "Money amounts cannot be negative.");
        }

        Amount = amount;
    }

    public static Money Brl(decimal amount) => new(amount);

    public static Money Zero { get; } = new(0m);

    public static Money operator +(Money left, Money right) => new(left.Amount + right.Amount);

    public static Money operator -(Money left, Money right) => new(left.Amount - right.Amount);

    public static bool operator >(Money left, Money right) => left.Amount > right.Amount;

    public static bool operator <(Money left, Money right) => left.Amount < right.Amount;

    public static bool operator >=(Money left, Money right) => left.Amount >= right.Amount;

    public static bool operator <=(Money left, Money right) => left.Amount <= right.Amount;

    public Money Percentage(decimal rate) => new(Math.Round(Amount * rate, 2, MidpointRounding.AwayFromZero));

    public override string ToString() => $"R$ {Amount:N2}";
}
