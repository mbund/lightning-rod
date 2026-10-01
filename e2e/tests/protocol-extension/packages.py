#!/usr/bin/env python3
"""Build this consumer using only independently archived Zig packages."""

import io
import pathlib
import re
import subprocess
import tarfile
import tempfile


def main():
    source = pathlib.Path(__file__).resolve().parent
    packages = {}
    visiting = set()
    with tempfile.TemporaryDirectory(prefix="lightning-rod-packages-") as directory:
        root = pathlib.Path(directory)

        def archive(path):
            path = path.resolve()
            if path in packages:
                return packages[path]
            if path in visiting:
                raise RuntimeError(f"Dependency cycle: {path}")
            visiting.add(path)
            manifest = (path / "build.zig.zon").read_text()

            def dependency(match):
                url, digest = archive(path / match[1])
                return f'.url = "{url}", .hash = "{digest}"'

            manifest = re.sub(r'\.path\s*=\s*"([^"\\]+)"', dependency, manifest)
            if re.search(r'\.path\s*=', manifest):
                raise RuntimeError(f"Unsupported dependency path in {path}")
            paths = re.search(r'\.paths\s*=\s*\.\{([^}]+)\}', manifest)
            if paths is None or re.sub(r'"[^"\\]+"|[\s,]', '', paths[1]):
                raise RuntimeError(f"Expected literal package paths in {path}")
            included = re.findall(r'"([^"\\]+)"', paths[1])
            output = root / f"package-{len(packages)}.tar.gz"
            with tarfile.open(output, "w:gz") as package:
                for name in included:
                    entry = path / name
                    if not entry.resolve().is_relative_to(path):
                        raise RuntimeError(f"Package path escapes {path}: {name}")
                    if name == "build.zig.zon":
                        data = manifest.encode()
                        info = tarfile.TarInfo(name)
                        info.size = len(data)
                        package.addfile(info, io.BytesIO(data))
                    else:
                        package.add(entry, arcname=name, filter=exclude)
            digest = subprocess.check_output(["zig", "fetch", str(output)], text=True).strip()
            packages[path] = (output.as_uri(), digest)
            visiting.remove(path)
            print(f"Packaged {path.name}: {digest}", flush=True)
            return packages[path]

        def exclude(info):
            if any(part in {".zig-cache", "zig-out", "zig-pkg", ".git"} for part in pathlib.PurePosixPath(info.name).parts):
                return None
            return info

        url, _ = archive(source)
        consumer = root / "consumer"
        consumer.mkdir()
        with tarfile.open(pathlib.Path(url.removeprefix("file://"))) as package:
            package.extractall(consumer, filter="data")
        subprocess.run(["zig", "build", "-j2", "-Doptimize=Debug"], cwd=consumer, check=True)
        print(f"Isolated downstream build passed with {len(packages)} packages.")


if __name__ == "__main__":
    main()
