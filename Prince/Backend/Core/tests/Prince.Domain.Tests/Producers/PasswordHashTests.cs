using Prince.Domain.Models.Producers;

namespace Prince.Domain.Tests.Producers;

public class PasswordHashTests
{
    [Fact]
    public void Matches_WithCorrectPassword_ReturnsTrue()
    {
        var hash = PasswordHash.Create("correct-horse-battery");

        Assert.True(hash.Matches("correct-horse-battery"));
    }

    [Fact]
    public void Matches_WithWrongPassword_ReturnsFalse()
    {
        var hash = PasswordHash.Create("correct-horse-battery");

        Assert.False(hash.Matches("wrong-password"));
    }

    [Fact]
    public void Create_SamePasswordTwice_ProducesDifferentStoredValues()
    {
        var first = PasswordHash.Create("correct-horse-battery");
        var second = PasswordHash.Create("correct-horse-battery");

        Assert.NotEqual(first.StoredValue, second.StoredValue);
    }

    [Fact]
    public void FromStoredValue_RehydratesAWorkingHash()
    {
        var original = PasswordHash.Create("correct-horse-battery");

        var rehydrated = PasswordHash.FromStoredValue(original.StoredValue);

        Assert.True(rehydrated.Matches("correct-horse-battery"));
    }

    [Theory]
    [InlineData("short")]
    [InlineData("")]
    public void Create_WithPasswordShorterThanEightCharacters_Throws(string password)
    {
        Assert.Throws<ArgumentException>(() => PasswordHash.Create(password));
    }
}
