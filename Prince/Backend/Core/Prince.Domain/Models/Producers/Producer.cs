using Prince.Domain.Models.Payments;
using Prince.Domain.Models.Shared;

namespace Prince.Domain.Models.Producers;

public enum ProducerVerificationStatus
{
    Pending,
    Verified
}

/// <summary>
/// A creator selling products on the platform. Producers can sell immediately after signing
/// up with just their name, email, and password — a full address and a CPF on file are only
/// required before their first withdrawal, matching how Brazilian payment gateways actually
/// gate payouts, not account creation or sales. This is the aggregate root for a producer's
/// balance: Transaction/Withdrawal only exist through the methods below, so the balance can
/// never drift out of sync with what actually funded or drew from it.
/// </summary>
public sealed class Producer
{
    public Guid Id { get; }
    public string Name { get; } = null!;
    public string Email { get; } = null!;
    public PasswordHash PasswordHash { get; private set; }
    public Address? Address { get; private set; }
    public Money Balance { get; private set; }
    public ProducerVerificationStatus VerificationStatus { get; private set; }
    public Cpf? Cpf { get; private set; }

    // For EF Core materialization only — bypasses Id/PasswordHash generation so reads don't mutate identity.
    private Producer() { }

    public Producer(string name, string email, string password)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("Producer name is required.", nameof(name));
        }

        if (string.IsNullOrWhiteSpace(email))
        {
            throw new ArgumentException("Producer email is required.", nameof(email));
        }

        Id = Guid.NewGuid();
        Name = name;
        Email = email;
        PasswordHash = PasswordHash.Create(password);
        Balance = Money.Zero;
        VerificationStatus = ProducerVerificationStatus.Pending;
    }

    /// <summary>
    /// Records a buyer's purchase of one of this producer's offers and credits the balance
    /// with the producer's share. <paramref name="amountPaid"/> is a snapshot of the offer's
    /// price at the moment of purchase — pass the offer's current price, not a live reference
    /// to the offer itself, so later price changes don't retroactively affect this transaction.
    /// </summary>
    public Transaction RecordTransaction(Guid offerId, Money amountPaid, Buyer buyer, PaymentMethod paymentMethod)
    {
        var transaction = new Transaction(Id, offerId, buyer, amountPaid, paymentMethod);
        Balance += transaction.ProducerNetAmount;
        return transaction;
    }

    /// <summary>Checks a login attempt's password against the stored hash.</summary>
    public bool Authenticate(string password) => PasswordHash.Matches(password);

    public void ChangePassword(string newPassword) => PasswordHash = PasswordHash.Create(newPassword);

    public void UpdateAddress(Address address) => Address = address ?? throw new ArgumentNullException(nameof(address));

    /// <summary>Registers the producer's CPF, unlocking withdrawals.</summary>
    public void RegisterCpf(Cpf cpf)
    {
        Cpf = cpf;
        VerificationStatus = ProducerVerificationStatus.Verified;
    }

    /// <summary>Cashes out part of the balance. Requires a registered CPF and sufficient funds.</summary>
    public Withdrawal RequestWithdrawal(Money amount, PaymentGateway gateway)
    {
        if (VerificationStatus != ProducerVerificationStatus.Verified)
        {
            throw new InvalidOperationException("Producer must have a valid CPF on file before withdrawing funds.");
        }

        if (amount > Balance)
        {
            throw new InvalidOperationException($"Withdrawal amount ({amount}) exceeds available balance ({Balance}).");
        }

        var withdrawal = new Withdrawal(Id, amount, gateway);
        Balance -= amount;
        return withdrawal;
    }
}
