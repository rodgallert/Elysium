using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Prince.Domain.Models.Payments;

namespace Prince.Data.Conversions;

internal static class MoneyValueConverter
{
    public static readonly ValueConverter<Money, decimal> Instance = new(
        money => money.Amount,
        amount => Money.Brl(amount));
}
