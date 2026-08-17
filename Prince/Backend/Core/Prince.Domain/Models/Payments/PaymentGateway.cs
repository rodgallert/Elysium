namespace Prince.Domain.Models.Payments;

/// <summary>The external payment processor a sale/withdrawal moves through.</summary>
public enum PaymentGateway
{
    PagarMe,
    MercadoPago
}

/// <summary>
/// Withdrawal fees the gateways charge when a producer cashes out their balance. This is a
/// pass-through cost, not company revenue — the platform pays the gateway this same amount
/// (see Withdrawal). Figure below is an illustrative "usually ~R$10" default, not a verified
/// real-world rate; give each gateway its own value here once real pricing is known.
/// </summary>
public static class PaymentGatewayFees
{
    private static readonly Money DefaultWithdrawalFee = Money.Brl(10.00m);

    public static Money WithdrawalFeeFor(PaymentGateway gateway) => gateway switch
    {
        PaymentGateway.PagarMe => DefaultWithdrawalFee,
        PaymentGateway.MercadoPago => DefaultWithdrawalFee,
        _ => throw new NotSupportedException($"No withdrawal fee defined for payment gateway: {gateway}")
    };
}
