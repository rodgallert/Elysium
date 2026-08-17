using Prince.Domain.Models.Shared;

namespace Prince.Domain.Models.Payments;

/// <summary>
/// Who a transaction was made for. The platform doesn't maintain buyer accounts — this is
/// just a snapshot of who paid, captured directly on the Transaction at purchase time.
/// </summary>
public sealed record Buyer
{
    public string Name { get; }
    public Cpf Cpf { get; }
    public string Email { get; }

    public Buyer(string name, Cpf cpf, string email)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("Buyer name is required.", nameof(name));
        }

        if (string.IsNullOrWhiteSpace(email))
        {
            throw new ArgumentException("Buyer email is required.", nameof(email));
        }

        Name = name;
        Cpf = cpf;
        Email = email;
    }
}
