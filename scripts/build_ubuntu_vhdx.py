"""Build a generic Hyper-V image on a disposable Ubuntu runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import tempfile


BASE = "https://cloud-images.ubuntu.com/noble/20261017"
IMAGE = "noble-server-cloudimg-amd64.img"
IMAGE_BYTES = 621284352
IMAGE_SHA = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
SIGNER = "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"
KEY_URL = "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x" + SIGNER
OUTPUT = "ubuntu-noble-amd64.vhdx"
GIB = 1024 ** 3


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for piece in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(piece)
    return result.hexdigest()


def fetch(url, path, limit):
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                    "--proto", "=https", "--proto-redir", "=https", "--retry", "2",
                    "--connect-timeout", "20", "--max-time", "900", "--max-filesize",
                    str(limit), "--output", str(path), url], check=True)
    if not 0 < path.stat().st_size <= limit:
        raise ValueError("Unexpected download size")


def verify_signed_source(work):
    sums, sig = work / "SHA256SUMS", work / "SHA256SUMS.gpg"
    ring, key = work / "trusted.gpg", work / "canonical.asc"
    gpg_home = work / "gnupg"
    gpg_home.mkdir(mode=0o700)
    fetch(KEY_URL, key, 2 * 1024 ** 2)
    fetch(BASE + "/SHA256SUMS", sums, 2 * 1024 ** 2)
    fetch(BASE + "/SHA256SUMS.gpg", sig, 65536)
    subprocess.run(["gpg", "--homedir", str(gpg_home), "--batch", "--no-options",
                    "--dearmor", "--output", str(ring), str(key)], check=True)
    result = subprocess.check_output(
        ["gpgv", "--homedir", str(gpg_home), "--status-fd", "1", "--keyring",
         str(ring), str(sig), str(sums)], text=True)
    trusted = any(line.startswith("[GNUPG:] VALIDSIG ") and
                  (line.split()[2] == SIGNER or line.split()[-1] == SIGNER)
                  for line in result.splitlines())
    if not trusted:
        raise ValueError("Canonical cloud signing fingerprint mismatch")
    pattern = r"([0-9a-f]{64}) [ *]" + re.escape(IMAGE)
    matches = [m[1] for line in sums.read_text().splitlines()
               if (m := re.fullmatch(pattern, line))]
    if matches != [IMAGE_SHA]:
        raise ValueError("Signed index does not contain the unique pinned image hash")
    return {"signatureKey": SIGNER, "signedIndexSha256": digest(sums),
            "signatureSha256": digest(sig), "url": BASE + "/" + IMAGE,
            "sha256": IMAGE_SHA, "bytes": IMAGE_BYTES}


def image_info(path, kind):
    info = json.loads(subprocess.check_output(
        ["qemu-img", "info", "-f", kind, "--output=json", str(path)]))
    size = info["virtual-size"]
    specific = info.get("format-specific", {}).get("data", {})
    if (info["format"] != kind or not 0 < size <= 20 * GIB
            or info.get("backing-filename") or info.get("full-backing-filename")
            or info.get("encrypted") or info.get("dirty-flag") or info.get("snapshots")
            or specific.get("data-file") or specific.get("corrupt")):
        raise ValueError("Unsupported image metadata")
    return size


def cap_output():
    # This bound applies only to the child creating the dynamic VHDX.
    resource.setrlimit(resource.RLIMIT_FSIZE, (6 * GIB, 6 * GIB))


def convert(src, dst):
    size = image_info(src, "qcow2")
    if dst.exists():
        raise FileExistsError(dst)
    subprocess.run(["qemu-img", "check", "-q", "-f", "qcow2", str(src)], check=True)
    subprocess.run(["qemu-img", "convert", "-f", "qcow2", "-O", "vhdx", "-o",
                    "subformat=dynamic", str(src), str(dst)], check=True, preexec_fn=cap_output)
    if image_info(dst, "vhdx") != size:
        raise ValueError("Conversion changed virtual size")
    subprocess.run(["qemu-img", "compare", "-q", "-f", "qcow2", "-F", "vhdx",
                    str(src), str(dst)], check=True)
    return {"file": dst.name, "sha256": digest(dst), "fileBytes": dst.stat().st_size,
            "sourceVirtualBytes": size, "outputVirtualBytes": size,
            "conversionSubformat": "dynamic", "qemuCompare": "passed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-source-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.verify_source_only == bool(args.output):
        parser.error("Choose exactly one of --verify-source-only or --output PATH")
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        source = verify_signed_source(work)
        if args.verify_source_only:
            print(json.dumps(source, indent=2))
            return
        commit = os.environ.get("GITHUB_SHA", "")
        if not re.fullmatch("[0-9a-f]{40}", commit):
            raise ValueError("A build needs the workflow source commit")
        out = args.output.resolve()
        if out.exists():
            raise FileExistsError(out)
        if min(shutil.disk_usage(work).free, shutil.disk_usage(out.parent).free) < 8 * GIB:
            raise ValueError("Insufficient runner disk space")
        src = work / IMAGE
        fetch(source["url"], src, IMAGE_BYTES)
        if src.stat().st_size != IMAGE_BYTES or digest(src) != IMAGE_SHA:
            raise ValueError("Downloaded QCOW2 differs from signed input")
        out.mkdir(mode=0o700)
        output = convert(src, out / OUTPUT)
        manifest = {"schema": 1, "sourceCommit": commit, "workflowRun": os.environ["GITHUB_RUN_ID"],
                    "source": source, "output": output,
                    "converter": subprocess.check_output(["qemu-img", "--version"], text=True).splitlines()[0]}
        manifest_path = out / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps({"manifestSha256": digest(manifest_path), **manifest}, indent=2))
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            print(f"Manifest SHA256: \x60{digest(manifest_path)}\x60\n\n"
                  f"VHDX SHA256: \x60{output['sha256']}\x60\n\n"
                  f"VHDX file: {output['fileBytes']} bytes. "
                  f"Guest disk: {output['outputVirtualBytes']} bytes.", file=summary)


if __name__ == "__main__":
    main()
