using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Prince.Domain.Models.Shared;

namespace Prince.Data.Conversions;

internal static class CpfValueConverter
{
    public static readonly ValueConverter<Cpf, string> Instance = new(
        cpf => cpf.Digits,
        digits => Cpf.Parse(digits));

    public static readonly ValueConverter<Cpf?, string?> NullableInstance = new(
        cpf => cpf.HasValue ? cpf.Value.Digits : null,
        digits => digits == null ? null : Cpf.Parse(digits));
}
