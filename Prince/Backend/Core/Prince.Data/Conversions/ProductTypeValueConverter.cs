using System.Text.Json;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Prince.Domain.Models.Products;

namespace Prince.Data.Conversions;

internal static class ProductTypeValueConverter
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        Converters = { new ProductTypeJsonConverter() }
    };

    public static readonly ValueConverter<ProductType, string> Instance = new(
        type => JsonSerializer.Serialize(type, SerializerOptions),
        json => JsonSerializer.Deserialize<ProductType>(json, SerializerOptions)!);
}
