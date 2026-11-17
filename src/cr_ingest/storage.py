from __future__ import annotations

import gzip

from google.cloud import storage


class BronzeWriter:
    def __init__(self, bucket: str):
        self._bucket_name = bucket
        self._bucket = storage.Client().bucket(bucket)

    def write(self, object_name: str, body: bytes) -> str:
        """Grava o corpo como veio (sem reserializar), comprimido. Nunca sobrescreve."""
        blob = self._bucket.blob(object_name)
        blob.content_encoding = None
        blob.upload_from_string(
            gzip.compress(body), content_type="application/gzip", if_generation_match=0
        )
        return f"gs://{self._bucket_name}/{object_name}"
