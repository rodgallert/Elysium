namespace Prince.Domain.Models.Producers;

/// <summary>A producer's full registered address (Brazilian format — street/number/CEP/UF).</summary>
public sealed record Address
{
    private static readonly HashSet<string> BrazilianStateCodes =
    [
        "AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO",
        "MA", "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI",
        "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO"
    ];

    public string Street { get; }
    public string Number { get; }
    public string? Complement { get; }
    public string Neighborhood { get; }
    public string City { get; }
    public string State { get; }
    public string PostalCode { get; }

    public Address(string street, string number, string? complement, string neighborhood, string city, string state, string postalCode)
    {
        if (string.IsNullOrWhiteSpace(street))
        {
            throw new ArgumentException("Street is required.", nameof(street));
        }

        if (string.IsNullOrWhiteSpace(number))
        {
            throw new ArgumentException("Number is required.", nameof(number));
        }

        if (string.IsNullOrWhiteSpace(neighborhood))
        {
            throw new ArgumentException("Neighborhood is required.", nameof(neighborhood));
        }

        if (string.IsNullOrWhiteSpace(city))
        {
            throw new ArgumentException("City is required.", nameof(city));
        }

        var normalizedState = state?.Trim().ToUpperInvariant() ?? "";
        if (!BrazilianStateCodes.Contains(normalizedState))
        {
            throw new ArgumentException($"'{state}' is not a valid Brazilian state code.", nameof(state));
        }

        var postalCodeDigits = new string((postalCode ?? "").Where(char.IsDigit).ToArray());
        if (postalCodeDigits.Length != 8)
        {
            throw new ArgumentException($"'{postalCode}' is not a valid CEP (postal code).", nameof(postalCode));
        }

        Street = street;
        Number = number;
        Complement = complement;
        Neighborhood = neighborhood;
        City = city;
        State = normalizedState;
        PostalCode = postalCodeDigits;
    }

    public override string ToString()
    {
        var complementPart = string.IsNullOrWhiteSpace(Complement) ? "" : $" - {Complement}";
        return $"{Street}, {Number}{complementPart}, {Neighborhood}, {City}/{State}, {PostalCode[..5]}-{PostalCode[5..]}";
    }
}
