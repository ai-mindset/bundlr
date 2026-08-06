import type { TargetPlatform } from "../domain/package_request.ts";

const PYTHON_BUILD = "20260718";
const PYTHON_VERSION = "3.12.13";
const RELEASE_BASE =
  `https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD}`;

export interface PythonDistribution {
  readonly target: TargetPlatform;
  readonly pythonVersion: string;
  readonly archiveUrl: URL;
  readonly sha256: string;
  readonly executablePath: string;
  readonly uvPlatform: string;
}

interface DistributionTarget {
  readonly triple: string;
  readonly sha256: string;
  readonly executablePath: string;
}

const DISTRIBUTIONS: Readonly<Record<TargetPlatform, DistributionTarget>> = {
  "linux-x86_64": {
    triple: "x86_64-unknown-linux-gnu",
    sha256: "5854aa6ec71cad00334d5065633c210b2e7feb40956767a59a91791cadcf0b79",
    executablePath: "bin/python3",
  },
  "macos-arm64": {
    triple: "aarch64-apple-darwin",
    sha256: "9a1e9e06175c10efd8378b904b07fa21bd791ab3345d7cdffeb4a76c9ff55903",
    executablePath: "bin/python3",
  },
  "macos-x86_64": {
    triple: "x86_64-apple-darwin",
    sha256: "8e6b7e6533bdf746287008edf91102e7bee0a6ca1d24f16c4514237cafd706c5",
    executablePath: "bin/python3",
  },
  "windows-x86_64": {
    triple: "x86_64-pc-windows-msvc",
    sha256: "0d422a1439ec308e03f47df551bc30f5994727c456e414b026d202bcda9b7c1c",
    executablePath: "python.exe",
  },
};

export function selectPythonDistribution(
  target: TargetPlatform,
  requestedVersion: string,
): PythonDistribution {
  if (requestedVersion !== "3.12" && requestedVersion !== PYTHON_VERSION) {
    throw new Error(
      `Bundlr currently supports Python 3.12 or ${PYTHON_VERSION}; requested ${requestedVersion}.`,
    );
  }

  const distribution = DISTRIBUTIONS[target];
  const filename =
    `cpython-${PYTHON_VERSION}+${PYTHON_BUILD}-${distribution.triple}-install_only_stripped.tar.gz`;
  return {
    target,
    pythonVersion: PYTHON_VERSION,
    archiveUrl: new URL(`${RELEASE_BASE}/${filename}`),
    sha256: distribution.sha256,
    executablePath: distribution.executablePath,
    uvPlatform: distribution.triple,
  };
}
