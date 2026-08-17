namespace Prince.Domain.Models.Shared;

/// <summary>A validated Brazilian individual taxpayer ID (CPF). Shared by Producer (required before withdrawing) and Buyer.</summary>
public readonly record struct Cpf
{
    public string Digits { get; }

    private Cpf(string digits) => Digits = digits;

    public static Cpf Parse(string input)
    {
        var digits = new string((input ?? "").Where(char.IsDigit).ToArray());

        if (digits.Length != 11 || AllDigitsAreTheSame(digits) || !HasValidCheckDigits(digits))
        {
            throw new ArgumentException($"'{input}' is not a valid CPF.", nameof(input));
        }

        return new Cpf(digits);
    }

    private static bool AllDigitsAreTheSame(string digits) => digits.Distinct().Count() == 1;

    private static bool HasValidCheckDigits(string digits)
    {
        var firstCheckDigit = CalculateCheckDigit(digits[..9], startingWeight: 10);
        var secondCheckDigit = CalculateCheckDigit(digits[..9] + firstCheckDigit, startingWeight: 11);

        return digits[9] - '0' == firstCheckDigit && digits[10] - '0' == secondCheckDigit;
    }

    private static int CalculateCheckDigit(string digits, int startingWeight)
    {
        var sum = 0;
        var weight = startingWeight;

        foreach (var digit in digits)
        {
            sum += (digit - '0') * weight;
            weight--;
        }

        var remainder = sum % 11;
        return remainder < 2 ? 0 : 11 - remainder;
    }

    public override string ToString() => $"{Digits[..3]}.{Digits[3..6]}.{Digits[6..9]}-{Digits[9..]}";
}
