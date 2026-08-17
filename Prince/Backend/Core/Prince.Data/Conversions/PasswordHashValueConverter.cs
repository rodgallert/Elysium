using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Prince.Domain.Models.Producers;

namespace Prince.Data.Conversions;

internal static class PasswordHashValueConverter
{
    public static readonly ValueConverter<PasswordHash, string> Instance = new(
        hash => hash.StoredValue,
        stored => PasswordHash.FromStoredValue(stored));
}
