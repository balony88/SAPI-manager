# SAPI-SK Manager

A PowerShell command-line client for SAPI-SK-compatible access points. It can
check an API connection, list received documents, download XML, acknowledge
receipt, and submit an XML document for delivery through Peppol.

Verified to work with [e-fakturuj.sk](https://e-fakturuj.sk/). Compatibility
with other providers depends on their implementation and has not been verified.
See [SAPI-SK](https://www.sapi-sk.sk/) for information about the interface.

## Requirements

- PowerShell
- A SAPI client registered with your access point, with its base URL, client ID,
  and client secret
- A Peppol participant ID for document operations (`Pull`, `Download`,
  `Acknowledge`, and `Send`)

## Configuration

Copy the example configuration file and fill in the values supplied by your
provider:

```powershell
Copy-Item .env.sapi.example .env.sapi
```

Edit `.env.sapi`:

```dotenv
APP_BASE_URL=https://your-access-point.example
CLIENT_ID=your-client-id
CLIENT_SECRET=your-client-secret
PEPPOL_PARTICIPANT_ID=0245:your-participant-id
```

`APP_BASE_URL` can be the portal origin or a URL ending in `/sapi`. The script
adds `/sapi` when constructing API requests. HTTPS is required except for
`localhost` and loopback addresses. Redirects are not followed.

Keep `.env.sapi` private. It contains credentials and is excluded from Git by
`.gitignore`. Do not share or commit it. You can use a different configuration
file with `-ConfigPath`.

## Usage

Run commands from the project directory:

```powershell
.\SAPI-manager.ps1 -TestConnect
```

If PowerShell blocks the script because of the execution policy, you may need
to allow it to run. Avoid changing the machine-wide policy to `Unrestricted`.
For a temporary, current-session-only setting, run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Then run the script in that same PowerShell session. The setting is discarded
when the session closes.

With no operation switch, the script also requests a token and checks its
validity. The access token is never printed.

### List received documents

```powershell
.\SAPI-manager.ps1 -Pull
.\SAPI-manager.ps1 -Pull -Limit 10 -Status RECEIVED
.\SAPI-manager.ps1 -Pull -Limit 10 -PageToken '<page-token>'
```

`-Limit` accepts values from 1 to 100 and defaults to 20. `-Status` can be
`RECEIVED` or `ACKNOWLEDGED`. The response contains one page of document
metadata; use the returned page token with `-PageToken` to request the next
page.

### Download a document

```powershell
.\SAPI-manager.ps1 -Download -DocumentId '<document-id>' -OutputPath .\document.xml
```

Downloading does **not** acknowledge the document. The script will not
overwrite an existing output file.

### Acknowledge receipt

```powershell
.\SAPI-manager.ps1 -Acknowledge -DocumentId '<document-id>'
```

Acknowledgement records technical receipt only; it is not approval or payment.

### Send a document

```powershell
.\SAPI-manager.ps1 `
  -Send `
  -XmlPath .\invoice.xml `
  -MetadataPath .\metadata.json `
  -IdempotencyKey '123e4567-e89b-42d3-a456-426614174000'
```

Sending submits the document to the access point for Peppol delivery and may
create a real business document. Verify the XML and metadata before sending.
The metadata JSON must contain non-empty values for:

- `documentId`
- `documentTypeId`
- `processId`
- `senderParticipantId`
- `receiverParticipantId`
- `creationDateTime`

[metadata.example.json](metadata.example.json) provides an invoice example;
replace its sample values with values appropriate for the actual document and
profile. The `senderParticipantId` must match the configured Peppol participant
ID.

An `ACCEPTED` response means technical acceptance only, not successful delivery.
The script does not automatically retry sending. If the result is uncertain,
check the document's status before retrying. Any retry must use the same
idempotency key, metadata, and XML; do not generate a new key for the same
submission.

## Parameters

| Parameter | Description |
| --- | --- |
| `-ConfigPath` | Path to a configuration file; defaults to `.env.sapi` beside the script. |
| `-TestConnect` | Check token validity. |
| `-Pull` | List a page of received documents. |
| `-Download` | Download a document's XML payload. |
| `-Acknowledge` | Record technical receipt of a document. |
| `-Send` | Submit an XML document for sending. |
| `-ParticipantId` | Peppol participant ID; overrides the configured value. |
| `-DocumentId` | Document ID for `-Download` or `-Acknowledge`. |
| `-OutputPath` | Destination path for `-Download`. |
| `-XmlPath` | XML input path for `-Send`. |
| `-MetadataPath` | JSON metadata path for `-Send`. |
| `-IdempotencyKey` | UUID idempotency key required for `-Send`. |
| `-Limit` | Number of documents requested by `-Pull` (1–100, default 20). |
| `-PageToken` | Page token for `-Pull`. |
| `-Status` | Optional `RECEIVED` or `ACKNOWLEDGED` filter for `-Pull`. |

Choose at most one operation switch (`-TestConnect`, `-Pull`, `-Download`,
`-Acknowledge`, or `-Send`) per invocation.

## License

This project is licensed under the [MIT License](LICENSE). The copyright
attribution must be retained in copies or substantial portions of the software.
