# Verifying bundlr Binary Integrity

This guide explains how to verify that the bundlr binaries you download are authentic and haven't been tampered with.

## Why Verify?

Binary verification ensures:
- **Integrity**: The file hasn't been corrupted during download
- **Authenticity**: The binary was built by our official CI pipeline
- **Security**: No malicious modifications have been made

## Quick Verification Methods

### Method 1: SHA256 Checksum Verification (Recommended)

Every release includes SHA256 checksums for all binaries. This is the fastest way to verify your download.

#### Linux/macOS

```bash
# Download the binary and its checksum
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-linux-x86_64
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-linux-x86_64.sha256

# Verify the checksum
echo "$(cat bundlr-linux-x86_64.sha256)  bundlr-linux-x86_64" | shasum -a 256 -c -
```

You should see: `bundlr-linux-x86_64: OK`

#### Windows (PowerShell)

```powershell
# Download the binary and its checksum
Invoke-WebRequest -Uri "https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-windows-x86_64.exe" -OutFile "bundlr-windows-x86_64.exe"
Invoke-WebRequest -Uri "https://github.com/ai-mindset/bundlr/releases/download/VERSION/bundlr-windows-x86_64.exe.sha256" -OutFile "bundlr-windows-x86_64.exe.sha256"

# Verify the checksum
$expected = Get-Content bundlr-windows-x86_64.exe.sha256
$actual = (Get-FileHash bundlr-windows-x86_64.exe -Algorithm SHA256).Hash.ToLower()
if ($expected -eq $actual) { 
    Write-Host "✓ Checksum verified!" -ForegroundColor Green 
} else { 
    Write-Host "✗ Checksum mismatch! Do not use this binary." -ForegroundColor Red 
}
```

#### Verifying Multiple Binaries

Each release includes a `SHA256SUMS` file with checksums for all binaries:

```bash
# Download SHA256SUMS file
curl -LO https://github.com/ai-mindset/bundlr/releases/download/VERSION/SHA256SUMS

# Verify all downloaded binaries at once
shasum -a 256 -c SHA256SUMS --ignore-missing
```

### Method 2: SLSA Build Provenance (Advanced)

We use [SLSA (Supply chain Levels for Software Artifacts)](https://slsa.dev/) to provide cryptographic proof that binaries were built by our official GitHub Actions pipeline.

#### Prerequisites

Install the [GitHub CLI](https://cli.github.com/):
- macOS: `brew install gh`
- Linux: See [installation instructions](https://github.com/cli/cli#installation)
- Windows: Download from [releases page](https://github.com/cli/cli/releases)

#### Verify Build Provenance

```bash
# Authenticate with GitHub (first time only)
gh auth login

# Verify a binary
gh attestation verify bundlr-linux-x86_64 --repo ai-mindset/bundlr
```

This command:
1. Downloads the cryptographic attestation for the binary
2. Verifies it was signed by GitHub Actions
3. Confirms the binary was built from our repository's official workflow

**What you'll see on success:**
```
Loaded digest sha256:... for file://bundlr-linux-x86_64
Loaded 1 attestation from GitHub API
✓ Verification succeeded!

sha256:... was attested by:
REPO        PREDICATE_TYPE           WORKFLOW
ai-mindset/bundlr  https://slsa.dev/provenance/v1  .github/workflows/release.yml@refs/tags/vX.X.X
```

## Comparing with Local Builds

If you build bundlr locally, you can compare checksums:

### Building Locally

```bash
git clone https://github.com/ai-mindset/bundlr.git
cd bundlr
git checkout VERSION  # Use the same version tag as the release

# Build with the same flags as CI
# Ensure these environment variables are NOT set
unset BUNDLR_PROJECT_NAME BUNDLR_PROJECT_VERSION BUNDLR_PYTHON_VERSION

zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux

# Generate checksum
shasum -a 256 zig-out/bin/bundlr
```

### Understanding Build Reproducibility

**Important Note**: Zig builds are mostly reproducible, but some factors may cause differences:

1. **Zig Version**: Must match exactly (check `.github/workflows/release.yml` for the version - currently 0.15.2)
2. **Build Flags**: Must use `-Doptimize=ReleaseFast` and correct `-Dtarget=`
3. **Environment Variables**: The build uses optional environment variables that should NOT be set:
   - `BUNDLR_PROJECT_NAME`
   - `BUNDLR_PROJECT_VERSION`
   - `BUNDLR_PYTHON_VERSION`
   
   These are intentionally not set in CI to ensure consistency.
4. **Build Environment**: Minor differences in build environment may affect the binary
5. **Build Timestamps**: May be embedded in the binary

Even with these factors, the functional behavior and security of the binary should be identical. The SLSA attestation provides stronger guarantees than bit-by-bit reproducibility.

## What to Do if Verification Fails

**If checksum verification fails:**

1. ❌ **DO NOT use the binary**
2. 🔄 Try downloading again (might be a network error)
3. 🔍 Check you downloaded from the official GitHub releases page
4. 🚨 If it still fails, [report it immediately](https://github.com/ai-mindset/bundlr/issues/new)

**If attestation verification fails:**

1. ❌ **DO NOT use the binary**
2. 🔍 Ensure you're using the correct repository: `ai-mindset/bundlr`
3. 🔄 Update GitHub CLI: `gh version` (should be v2.40.0+)
4. 🚨 If it still fails, [report it immediately](https://github.com/ai-mindset/bundlr/issues/new)

## Security Best Practices

1. ✅ **Always verify checksums** before using downloaded binaries
2. ✅ **Download from official releases** at https://github.com/ai-mindset/bundlr/releases
3. ✅ **Use HTTPS** when downloading (curl/wget will do this by default)
4. ✅ **Keep the checksums** in a separate, secure location if distributing binaries
5. ✅ **Verify attestations** for high-security environments

## Automated Verification in Scripts

### Bash Script Example

```bash
#!/bin/bash
set -e

VERSION="v1.0.0"
PLATFORM="linux-x86_64"
BINARY="bundlr-${PLATFORM}"
BASE_URL="https://github.com/ai-mindset/bundlr/releases/download/${VERSION}"

# Download binary and checksum
curl -LO "${BASE_URL}/${BINARY}"
curl -LO "${BASE_URL}/${BINARY}.sha256"

# Verify
echo "$(cat ${BINARY}.sha256)  ${BINARY}" | shasum -a 256 -c - || {
    echo "Checksum verification failed!"
    exit 1
}

echo "✓ Binary verified successfully"
chmod +x "${BINARY}"
```

### PowerShell Script Example

```powershell
$ErrorActionPreference = "Stop"

$version = "v1.0.0"
$binary = "bundlr-windows-x86_64.exe"
$baseUrl = "https://github.com/ai-mindset/bundlr/releases/download/$version"

# Download
Invoke-WebRequest -Uri "$baseUrl/$binary" -OutFile $binary
Invoke-WebRequest -Uri "$baseUrl/$binary.sha256" -OutFile "$binary.sha256"

# Verify
$expected = (Get-Content "$binary.sha256").Trim()
$actual = (Get-FileHash $binary -Algorithm SHA256).Hash.ToLower()

if ($expected -ne $actual) {
    Write-Error "Checksum verification failed!"
    exit 1
}

Write-Host "✓ Binary verified successfully" -ForegroundColor Green
```

## Additional Resources

- [SLSA Framework](https://slsa.dev/) - Supply chain security framework
- [GitHub Artifact Attestations](https://github.blog/changelog/2024-06-25-artifact-attestations-is-generally-available/) - Official documentation
- [SHA-256 Hash](https://en.wikipedia.org/wiki/SHA-2) - Technical background

## Questions?

If you have questions about verification or encounter issues, please [open an issue](https://github.com/ai-mindset/bundlr/issues/new).
