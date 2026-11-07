"""One cooperative packaging state machine, used by the CLI and loopback interface."""
import time;
import sys;
import from src.domain.request { PackageRequest, validate_request, PYTHON_VERSION }
import from src.core.distribution { distribution, PythonDistribution }
import from src.core.metadata {
    EntryPoint,
    installed_entry_point,
    portable_git_wheel,
    wheel_requirements,
    write_manifest,
    write_dependencies,
    HashTask,
    EvidenceTask
}
import from src.core.launchers { resources_path, create_launcher }
import from src.platform.files {
    join_path,
    base_name,
    absolute_path,
    make_dirs,
    temp_dir,
    stat_path,
    require_absent,
    remove_tree,
    read_text,
    write_text,
    hard_link
}
import from src.platform.publication { publish_directory }
import from src.platform.urls { validate_git_url }
import from src.platform.uv_runtime { resolve_uv }
import from src.platform.processes { Child, ProcessEvents, start_child }
import from src.platform.downloads { Download }
import from src.platform.archives { Extractor, ArchiveWriter, ArchiveMetadata }

obj:pub BuildEvents(ProcessEvents) {
    def finished(results: list[dict[str, str]]) {
        for result in results {
            self.stdout(
                f"Created {result['archivePath']} for {result['target']} ({result[
                    'sha256'
                ]}).\n"
            );
        }
    }

    def failed(message: str) {
        self.stderr("Error: " + message + "\n");
    }
}

def:pub binary_install_args(
    requirements: list[str], target: str, packages: str
) -> list[str] {
    args = [
        "--no-config",
        "pip",
        "install",
        "--target",
        packages,
        "--python-version",
        PYTHON_VERSION,
        "--python-platform",
        distribution(target).triple,
        "--only-binary",
        ":all:",
        "--no-installer-metadata"
    ];
    args.extend(requirements);
    return args;
}

def install_environment -> dict[str, str] {
    return {
        "UV_NO_SYSTEM_CONFIG": "1",
        "UV_PYTHON_PREFERENCE": "only-managed",
        "UV_LINK_MODE": "copy"
    };
}

obj:pub BuildJob {
    has request: PackageRequest,
        events: BuildEvents,
        done: bool = False,
        cancelled: bool = False,
        error: str = "",
        phase: str = "begin",
        target_index: int = 0,
        target: str = "",
        staging: str = "",
        artifact_name: str = "",
        resources: str = "",
        packages: str = "",
        artifact_path: str = "",
        archive_path: str = "",
        archive_digest: str = "",
        download: Download | None = None,
        extractor: Extractor | None = None,
        writer: ArchiveWriter | None = None,
        hashing: HashTask | None = None,
        evidence: EvidenceTask | None = None,
        child: Child | None = None,
        point: EntryPoint | None = None,
        python_distribution: PythonDistribution | None = None,
        results: list[dict[str, str]] = [],
        published_artifact: bool = False,
        published_archive: bool = False,
        published_checksum: bool = False,
        archive_metadata: ArchiveMetadata = ArchiveMetadata();

    def start {
        validate_request(self.request);
        if self.request.source.kind == "git" {
            validate_git_url(self.request.source.value);
        }
        self.request.outputDirectory = absolute_path(self.request.outputDirectory);
        for target in self.request.targets {
            artifact = join_path(
                self.request.outputDirectory,
                self.request.applicationName + "-" + target
            );
            require_absent(artifact + (".app" if target.startswith("macos-") else ""));
            archive = artifact + (".zip" if target == "windows-x86_64" else ".tar.gz");
            require_absent(archive);
            require_absent(archive + ".sha256");
        }
        make_dirs(self.request.outputDirectory);
    }

    def cancel {
        self.cancelled = True;
        child = self.child;
        if child is not None {
            child.cancel();
        }
    }

    def advance {
        if self.done {
            return;
        }
        try {
            if self.cancelled {
                child = self.child;
                if child is not None and not child.done() {
                    return;
                }
                raise RuntimeError("Build cancelled.");
            }
            self.advance_phase();
        } except Exception as error {
            self.error = str(error);
            try {
                self.cleanup();
            } except Exception as cleanup_error {
                self.error += " Cleanup failed: " + str(cleanup_error);
            }
            self.done = True;
            self.events.failed(self.error);
        }
    }

    def advance_phase {
        if self.phase == "begin" {
            self.begin_target();
            return;
        }
        if self.phase == "download" {
            task = self.download;
            if task is None {
                raise RuntimeError("Missing download operation.");
            }
            task.advance();
            if not task.done {
                return;
            }
            if task.error != "" {
                raise RuntimeError("Python runtime download failed: " + task.error);
            }
            self.download = None;
            self.hashing = HashTask(path=join_path(self.staging, "python.tar.gz"));
            self.hashing.start();
            self.phase = "verify";
            return;
        }
        if self.phase == "verify" {
            hashing = self.hashing;
            selected = self.python_distribution;
            if hashing is None or selected is None {
                raise RuntimeError("Missing runtime verification operation.");
            }
            hashing.advance();
            if not hashing.done {
                return;
            }
            if hashing.digest != selected.sha256 {
                raise RuntimeError("Python runtime failed SHA-256 verification.");
            }
            self.hashing = None;
            self.extractor = Extractor(
                source=join_path(self.staging, "python.tar.gz"),
                destination=join_path(self.resources, "runtime")
            );
            self.extractor.start();
            self.phase = "extract";
            return;
        }
        if self.phase == "extract" {
            extractor = self.extractor;
            selected = self.python_distribution;
            if extractor is None or selected is None {
                raise RuntimeError("Missing runtime extraction operation.");
            }
            extractor.advance();
            if not extractor.done {
                return;
            }
            self.archive_metadata = extractor.metadata;
            self.extractor = None;
            executable_path = join_path(
                self.resources, "runtime/" + selected.executable
            );
            if not stat_path(executable_path).exists
                and executable_path not in self.archive_metadata.symlinks {
                raise RuntimeError("The Python runtime is missing its executable.");
            }
            self.events.stderr(
                f"Installing target-compatible wheels for {self.target}...\n"
            );
            args: list[str] = [];
            if self.request.source.kind == "git" {
                args = [
                    "--no-config",
                    "pip",
                    "install",
                    "--target",
                    self.packages,
                    "--no-deps",
                    "--no-installer-metadata",
                    "git+" + self.request.source.value
                ];
            } else {
                args = binary_install_args(
                    [self.request.source.value], self.target, self.packages
                );
            }
            self.child = start_child(
                resolve_uv(), args, self.events, install_environment()
            );
            self.phase = "install";
            return;
        }
        if self.phase == "install" or self.phase == "dependencies" {
            child = self.child;
            if child is None {
                raise RuntimeError("Missing package installation operation.");
            }
            if not child.done() {
                return;
            }
            if child.code != 0 {
                raise RuntimeError(
                    f"Package installation failed with exit code {child.code}. Target dependencies must provide compatible wheels."
                );
            }
            self.child = None;
            if self.phase == "install" {
                source_name = "";
                if self.request.source.kind == "pypi" {
                    source_name = self.request.source.inferred_name;
                }
                point = installed_entry_point(
                    self.packages, self.request.command, source_name
                );
                self.point = point;
                if self.request.source.kind == "git" {
                    portable_git_wheel(
                        read_text(join_path(point.metadata_directory, "WHEEL"))
                    );
                    requirements = wheel_requirements(
                        read_text(join_path(point.metadata_directory, "METADATA"))
                    );
                    if len(requirements) > 0 {
                        self.child = start_child(
                            resolve_uv(),
                            binary_install_args(
                                requirements, self.target, self.packages
                            ),
                            self.events,
                            install_environment()
                        );
                        self.phase = "dependencies";
                        return;
                    }
                }
            }
            self.phase = "launchers";
            return;
        }
        if self.phase == "launchers" {
            resolved_point = self.point;
            if resolved_point is None {
                raise RuntimeError("Missing application entry point.");
            }
            kind = self.request.applicationKind;
            if kind == "auto" {
                kind = resolved_point.kind;
            }
            effective = PackageRequest(
                source=self.request.source,
                applicationName=self.request.applicationName,
                applicationKind=kind,
                command=self.request.command,
                python=self.request.python,
                targets=[self.target],
                outputDirectory=self.request.outputDirectory
            );
            launcher = create_launcher(
                effective,
                join_path(self.staging, self.artifact_name),
                self.target,
                resolved_point
            );
            self.archive_metadata.modes[launcher] = 493;
            if sys.platform == "win32" and self.target != "windows-x86_64" {
                self.archive_metadata.executable_roots = [self.packages];
            }
            write_manifest(effective, self.resources, self.target, resolved_point);
            write_dependencies(self.resources, self.packages);
            self.evidence = EvidenceTask(
                directory=self.resources, metadata=self.archive_metadata
            );
            self.evidence.start();
            self.phase = "evidence";
            return;
        }
        if self.phase == "evidence" {
            evidence = self.evidence;
            if evidence is None {
                raise RuntimeError("Missing evidence operation.");
            }
            evidence.advance();
            if not evidence.done {
                return;
            }
            self.evidence = None;
            self.writer = ArchiveWriter(
                source=join_path(self.staging, self.artifact_name),
                destination=join_path(self.staging, base_name(self.archive_path)),
                windows_zip=self.target == "windows-x86_64",
                metadata=self.archive_metadata
            );
            self.writer.start();
            self.phase = "archive";
            return;
        }
        if self.phase == "archive" {
            writer = self.writer;
            if writer is None {
                raise RuntimeError("Missing archive operation.");
            }
            writer.advance();
            if not writer.done {
                return;
            }
            self.writer = None;
            self.hashing = HashTask(
                path=join_path(self.staging, base_name(self.archive_path))
            );
            self.hashing.start();
            self.phase = "checksum";
            return;
        }
        if self.phase == "checksum" {
            hashing = self.hashing;
            if hashing is None {
                raise RuntimeError("Missing archive checksum operation.");
            }
            hashing.advance();
            if not hashing.done {
                return;
            }
            self.archive_digest = hashing.digest;
            self.hashing = None;
            write_text(
                join_path(self.staging, base_name(self.archive_path) + ".sha256"),
                self.archive_digest + "  " + base_name(self.archive_path) + "\n"
            );
            self.phase = "publish";
            return;
        }
        if self.phase == "publish" {
            publish_directory(
                join_path(self.staging, self.artifact_name), self.artifact_path
            );
            self.published_artifact = True;
            hard_link(
                join_path(self.staging, base_name(self.archive_path)), self.archive_path
            );
            self.published_archive = True;
            hard_link(
                join_path(self.staging, base_name(self.archive_path) + ".sha256"),
                self.archive_path + ".sha256"
            );
            self.published_checksum = True;
            self.results.append(
                {
                    "artifactPath": self.artifact_path,
                    "target": self.target,
                    "archivePath": self.archive_path,
                    "checksumPath": self.archive_path + ".sha256",
                    "sha256": self.archive_digest
                }
            );
            remove_tree(self.staging);
            self.staging = "";
            self.published_artifact = False;
            self.published_archive = False;
            self.published_checksum = False;
            self.target_index += 1;
            self.phase = "begin";
        }
    }

    def begin_target {
        if self.target_index == len(self.request.targets) {
            self.done = True;
            self.events.finished(self.results);
            return;
        }
        self.target = self.request.targets[self.target_index];
        self.archive_metadata = ArchiveMetadata();
        self.python_distribution = distribution(self.target);
        name = self.request.applicationName + "-" + self.target;
        self.artifact_name = name
            + (".app" if self.target.startswith("macos-") else "");
        self.artifact_path = join_path(
            self.request.outputDirectory, self.artifact_name
        );
        self.archive_path = join_path(
            self.request.outputDirectory,
            name + (".zip" if self.target == "windows-x86_64" else ".tar.gz")
        );
        self.staging = temp_dir(self.request.outputDirectory, ".bundlr-build-");
        self.resources = resources_path(
            join_path(self.staging, self.artifact_name), self.target
        );
        self.packages = join_path(self.resources, "packages");
        make_dirs(self.packages);
        self.events.stderr(
            f"\nPackaging {self.target}...\nDownloading Python {PYTHON_VERSION} for {self.target}...\n"
        );
        selected = self.python_distribution;
        if selected is None {
            raise RuntimeError("Missing Python distribution.");
        }
        self.download = Download(
            url=selected.url(), destination=join_path(self.staging, "python.tar.gz")
        );
        self.download.start();
        self.phase = "download";
    }

    def cleanup {
        download = self.download;
        if download is not None {
            download.close();
            self.download = None;
        }
        extractor = self.extractor;
        if extractor is not None {
            extractor.close();
            self.extractor = None;
        }
        writer = self.writer;
        if writer is not None {
            writer.close(False);
            self.writer = None;
        }
        hashing = self.hashing;
        if hashing is not None {
            hashing.close();
            self.hashing = None;
        }
        evidence = self.evidence;
        if evidence is not None {
            evidence.close();
            self.evidence = None;
        }
        if self.published_checksum {
            remove_tree(self.archive_path + ".sha256");
        }
        if self.published_archive {
            remove_tree(self.archive_path);
        }
        if self.published_artifact {
            remove_tree(self.artifact_path);
        }
        if self.staging != "" {
            remove_tree(self.staging);
            self.staging = "";
        }
    }
}
