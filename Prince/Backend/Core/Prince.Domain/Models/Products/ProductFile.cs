namespace Prince.Domain.Models.Products;

/// <summary>
/// A file uploaded by the producer and stored on the platform's object storage (see the
/// `file-storage` service in docker-compose.yml — MinIO, an S3-compatible self-hosted
/// alternative to AWS S3). StorageKey is the object's key/path within that storage, not a
/// public URL — actual download access (e.g. presigned URLs) is an App/Services concern,
/// not something Domain should know how to construct.
/// </summary>
public sealed record ProductFile
{
    public string StorageKey { get; }
    public string FileName { get; }
    public long SizeInBytes { get; }
    public string ContentType { get; }

    public ProductFile(string storageKey, string fileName, long sizeInBytes, string contentType)
    {
        if (string.IsNullOrWhiteSpace(storageKey))
        {
            throw new ArgumentException("Storage key is required.", nameof(storageKey));
        }

        if (string.IsNullOrWhiteSpace(fileName))
        {
            throw new ArgumentException("File name is required.", nameof(fileName));
        }

        if (sizeInBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sizeInBytes), "File size must be greater than zero.");
        }

        if (string.IsNullOrWhiteSpace(contentType))
        {
            throw new ArgumentException("Content type is required.", nameof(contentType));
        }

        StorageKey = storageKey;
        FileName = fileName;
        SizeInBytes = sizeInBytes;
        ContentType = contentType;
    }
}
