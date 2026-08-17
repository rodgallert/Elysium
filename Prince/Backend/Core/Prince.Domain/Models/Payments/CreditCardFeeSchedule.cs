using System.Diagnostics;

namespace Prince.Domain.Models.Payments;

/// <summary>
/// Prices the platform's markup on card/installment sales — this fee is company revenue,
/// unlike the gateway's withdrawal fee (see PaymentGatewayFees), which is a pass-through cost.
/// Rates below are an illustrative example schedule, not sourced from a specific gateway's
/// real pricing — swap in real figures when the business has actual numbers to price against.
/// </summary>
public static class CreditCardFeeSchedule
{
    private const decimal SingleInstallmentRate = 0.0299m; // 1x / à vista
    private const decimal ShortInstallmentRate = 0.0399m;  // 2x-6x
    private const decimal LongInstallmentRate = 0.0499m;   // 7x-12x

    public static Money Calculate(Money grossAmount, PaymentMethod method) => method switch
    {
        PaymentMethod.CreditCard creditCard => grossAmount.Percentage(RateFor(creditCard.Installments)),
        PaymentMethod.Pix => Money.Zero,
        PaymentMethod.Boleto => Money.Zero,
        PaymentMethod.DebitCard => Money.Zero,
        _ => throw new NotSupportedException($"No fee schedule defined for payment method: {method.GetType().Name}")
    };

    private static decimal RateFor(int installments) => installments switch
    {
        1 => SingleInstallmentRate,
        >= 2 and <= 6 => ShortInstallmentRate,
        >= 7 and <= 12 => LongInstallmentRate,
        _ => throw new UnreachableException("PaymentMethod.CreditCard already validates installments are between 1 and 12.")
    };
}
