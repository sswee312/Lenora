# Lenora Backend Protocol v1

`openapi.yaml` is the contract between the Lenora editor and any backend. `fixtures/` holds one example per schema, named `<Schema>.<variant>.json`; the backend and the app both test against them.

## Rules

1. The upload ticket names the final `assetRef`. There is no "complete upload" call.
2. Job IDs are opaque and must survive a backend restart.
3. `succeeded`, `failed` and `cancelled` are terminal and never change.
4. Each result names its `fileExtension`; clients never guess it from the URL.
5. Repeating `POST /v1/jobs` with the same `Idempotency-Key` returns the same job.
6. Errors are RFC 9457 `application/problem+json` with a stable `code` and `retryable`.
7. New kinds and new optional fields are compatible changes; clients ignore what they don't recognise. Breaking changes move to `/v2`.
8. `estimate` is informational and never gates a request.

Every request carries `Authorization: Bearer <token>`. `GET /v1/health` also answers without one, returning only `status` and `protocolVersion`.
