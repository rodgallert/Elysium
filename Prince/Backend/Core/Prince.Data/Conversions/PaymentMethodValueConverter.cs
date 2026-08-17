using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Prince.Domain.Models.Payments;

namespace Prince.Data.Conversions;

internal static class PaymentMethodValueConverter
{
    public static readonly ValueConverter<PaymentMethod, string> Instance = new(
        method => Serialize(method),
        value => Deserialize(value));

    private static string Serialize(PaymentMethod method) => method switch
    {
        PaymentMethod.Pix => "Pix",
        PaymentMethod.Boleto => "Boleto",
        PaymentMethod.DebitCard => "DebitCard",
        PaymentMethod.CreditCard creditCard => $"CreditCard:{creditCard.Installments}",
        _ => throw new NotSupportedException($"No storage encoding defined for payment method: {method.GetType().Name}")
    };

    private static PaymentMethod Deserialize(string value)
    {
        if (value == "Pix")
        {
            return new PaymentMethod.Pix();
        }

        if (value == "Boleto")
        {
            return new PaymentMethod.Boleto();
        }

        if (value == "DebitCard")
        {
            return new PaymentMethod.DebitCard();
        }

        if (value.StartsWith("CreditCard:", StringComparison.Ordinal))
        {
            var installments = int.Parse(value["CreditCard:".Length..]);
            return new PaymentMethod.CreditCard(installments);
        }

        throw new NotSupportedException($"Unrecognized payment method storage value: '{value}'");
    }
}
