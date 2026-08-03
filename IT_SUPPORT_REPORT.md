# Generated application: IT support request

Attach this completed page and the generated evidence files to one support ticket.

## Request

| Field                      | Value                                          |
| -------------------------- | ---------------------------------------------- |
| Application and purpose    | [name, version, one-sentence business purpose] |
| Requester / business owner | [names, teams, contacts]                       |
| User device                | [asset ID, OS, architecture]                   |
| Data classification        | [classification]                               |
| Required by                | [date or no deadline]                          |

Requested decision:

- [ ] Deploy through the approved endpoint-management platform.
- [ ] Allow the supplied immutable file hashes.
- [ ] Request additional evidence or remediation.
- [ ] Decline, with reason.

Do not create broad allow-list rules for temporary or user-writable directories.

## Artifact identity

| Field                   | Value                                                     |
| ----------------------- | --------------------------------------------------------- |
| Archive                 | [exact filename]                                          |
| Target                  | [Windows x64 / macOS ARM64 / macOS Intel / Linux x64]     |
| Source                  | [pinned PyPI version or HTTPS Git URL with full commit]   |
| Archive SHA-256         | [value from generated `.sha256` file]                     |
| Python / Bundlr version | [values from `bundlr-manifest.json`]                      |
| Build date and machine  | [UTC timestamp, controlled builder]                       |
| Publisher               | Unsigned; no publisher certificate is currently available |

The application is self-contained. It does not require or contain Bundlr, Deno, or uv, and it does
not use an existing Python installation.

## Behaviour

| Question                           | Answer                                  |
| ---------------------------------- | --------------------------------------- |
| Data read and written              | [paths and data types]                  |
| Network access                     | [destinations, ports, purpose, or none] |
| Credentials or secrets             | [storage mechanism or none]             |
| Child processes                    | [expected processes or none]            |
| Services, drivers, scheduled tasks | [details or none]                       |
| Registry, PATH, firewall changes   | [details or none]                       |
| Telemetry                          | [data, destination, opt-out, or none]   |

The embedded Python application runs with the signed-in user's normal permissions. It is not a
security sandbox.

## Evidence attached

- [ ] Client archive and archive `.sha256` file.
- [ ] `SHA256SUMS` file inventory.
- [ ] `bundlr-manifest.json` build identity.
- [ ] `bundlr-dependencies.json` dependency inventory.
- [ ] `THIRD_PARTY_LICENSES.txt`.
- [ ] Malware/EDR scan result.
- [ ] Clean-device acceptance-test result.

## Deployment and validation

| Field                        | Value                                     |
| ---------------------------- | ----------------------------------------- |
| Managed installation path    | [path]                                    |
| Installation command/process | [method]                                  |
| Detection rule               | [version or exact hash]                   |
| Validation                   | [double-click action and expected result] |
| Removal / rollback           | [managed process and retained user data]  |

Validate on a representative standard-user device without Python, uv, Deno, or Bundlr installed.
Removal must not delete unrelated Python installations, applications, or user documents.

## Approval

| Role                        | Name   | Decision and date |
| --------------------------- | ------ | ----------------- |
| Application owner           | [name] | [decision/date]   |
| Endpoint support / security | [name] | [decision/date]   |

Conditions, exceptions, or expiry: [details or none]
