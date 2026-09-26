"""
lib.storage.azure_blob – Azure Blob Storage client.

Uses DefaultAzureCredential so it works transparently with:
  - Workload Identity (AKS pods with federated credentials)
  - Managed Identity  (dev server VM with system-assigned identity)
  - Environment vars  (local development: AZURE_TENANT_ID / CLIENT_ID / CLIENT_SECRET)

Usage:
    from lib.storage.azure_blob import upload_bytes, download_bytes, list_blobs

    upload_bytes("market-data", "prices/2026-09-22.parquet", parquet_bytes)
    data = download_bytes("market-data", "prices/2026-09-22.parquet")
"""

from io import BytesIO
from typing import Iterator

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContainerClient

from lib.config.settings import get_settings

_client: BlobServiceClient | None = None


def _get_client() -> BlobServiceClient:
    global _client
    if _client is None:
        account_name = get_settings().azure_storage_account
        if not account_name:
            raise RuntimeError(
                "EQTECH_AZURE_STORAGE_ACCOUNT is not configured."
            )
        _client = BlobServiceClient(
            account_url=f"https://{account_name}.blob.core.windows.net",
            credential=DefaultAzureCredential(),
        )
    return _client


def get_container_client(container_name: str) -> ContainerClient:
    return _get_client().get_container_client(container_name)


def upload_bytes(container_name: str, blob_name: str, data: bytes) -> None:
    """Upload raw bytes to a blob, overwriting if it already exists."""
    get_container_client(container_name).upload_blob(
        name=blob_name, data=data, overwrite=True
    )


def download_bytes(container_name: str, blob_name: str) -> bytes:
    """Download a blob and return its contents as bytes."""
    return get_container_client(container_name).download_blob(blob_name).readall()


def download_stream(container_name: str, blob_name: str) -> BytesIO:
    """Return a seekable BytesIO stream for a blob (useful with pandas.read_parquet)."""
    raw = download_bytes(container_name, blob_name)
    return BytesIO(raw)


def list_blobs(container_name: str, prefix: str = "") -> Iterator[str]:
    """Yield blob names in a container, optionally filtered by prefix."""
    for blob in get_container_client(container_name).list_blobs(name_starts_with=prefix):
        yield blob.name
