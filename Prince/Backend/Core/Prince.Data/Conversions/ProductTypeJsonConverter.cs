using System.Text.Json;
using System.Text.Json.Serialization;
using Prince.Domain.Models.Products;

namespace Prince.Data.Conversions;

/// <summary>
/// Hand-written polymorphic (de)serialization for ProductType, kept in Prince.Data rather than
/// as [JsonDerivedType] attributes on the Domain type itself — serialization strategy is a
/// persistence concern, Domain shouldn't need to know it'll end up as JSON.
/// </summary>
internal sealed class ProductTypeJsonConverter : JsonConverter<ProductType>
{
    public override ProductType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        var kind = root.GetProperty("kind").GetString();

        return kind switch
        {
            "digital-download" => new ProductType.DigitalDownload(new ProductFile(
                root.GetProperty("storageKey").GetString()!,
                root.GetProperty("fileName").GetString()!,
                root.GetProperty("sizeInBytes").GetInt64(),
                root.GetProperty("contentType").GetString()!)),
            "content-platform-access" => new ProductType.ContentPlatformAccess(),
            "course" => new ProductType.Course(),
            _ => throw new NotSupportedException($"Unrecognized ProductType kind: '{kind}'")
        };
    }

    public override void Write(Utf8JsonWriter writer, ProductType value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();

        switch (value)
        {
            case ProductType.DigitalDownload digitalDownload:
                writer.WriteString("kind", "digital-download");
                writer.WriteString("storageKey", digitalDownload.File.StorageKey);
                writer.WriteString("fileName", digitalDownload.File.FileName);
                writer.WriteNumber("sizeInBytes", digitalDownload.File.SizeInBytes);
                writer.WriteString("contentType", digitalDownload.File.ContentType);
                break;
            case ProductType.ContentPlatformAccess:
                writer.WriteString("kind", "content-platform-access");
                break;
            case ProductType.Course:
                writer.WriteString("kind", "course");
                break;
            default:
                throw new NotSupportedException($"No JSON encoding defined for product type: {value.GetType().Name}");
        }

        writer.WriteEndObject();
    }
}
