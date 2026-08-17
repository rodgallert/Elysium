using System.Security.Cryptography;

namespace Prince.Domain.Models.Producers;

/// <summary>
/// A salted PBKDF2 password hash — never stores or logs the plaintext password. Uses only BCL
/// crypto (no NuGet package), keeping Prince.Domain dependency-free. 210,000 iterations follows
/// OWASP's current PBKDF2-HMAC-SHA256 recommendation; bump it as guidance evolves.
/// </summary>
public readonly record struct PasswordHash
{
    private const int SaltSizeBytes = 16;
    private const int HashSizeBytes = 32;
    private const int Iterations = 210_000;
    private static readonly HashAlgorithmName Algorithm = HashAlgorithmName.SHA256;

    public string StoredValue { get; }

    private PasswordHash(string storedValue) => StoredValue = storedValue;

    public static PasswordHash Create(string plainTextPassword)
    {
        if (string.IsNullOrWhiteSpace(plainTextPassword) || plainTextPassword.Length < 8)
        {
            throw new ArgumentException("Password must be at least 8 characters long.", nameof(plainTextPassword));
        }

        var salt = RandomNumberGenerator.GetBytes(SaltSizeBytes);
        var hash = Rfc2898DeriveBytes.Pbkdf2(plainTextPassword, salt, Iterations, Algorithm, HashSizeBytes);

        return new PasswordHash($"{Convert.ToBase64String(salt)}.{Convert.ToBase64String(hash)}");
    }

    /// <summary>Rehydrates a hash already computed by <see cref="Create"/> — for loading a producer from storage.</summary>
    public static PasswordHash FromStoredValue(string storedValue) => new(storedValue);

    public bool Matches(string plainTextPassword)
    {
        var parts = StoredValue.Split('.');
        var salt = Convert.FromBase64String(parts[0]);
        var expectedHash = Convert.FromBase64String(parts[1]);

        var actualHash = Rfc2898DeriveBytes.Pbkdf2(plainTextPassword, salt, Iterations, Algorithm, HashSizeBytes);

        return CryptographicOperations.FixedTimeEquals(expectedHash, actualHash);
    }
}
