"""Small synthetic images. The Ubuntu download is not used by these tests."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_ubuntu_vhdx as builder


class ImageBounds(unittest.TestCase):
    def test_reject_oversized_backed_or_external_images(self):
        for info in ({"virtual-size": 21 * builder.GIB}, {"backing-filename": "parent"},
                     {"format-specific": {"data": {"data-file": "external.raw"}}}):
            sample = {"format": "qcow2", "virtual-size": 16 * 1024 ** 2, **info}
            with self.subTest(info=info), patch("subprocess.check_output", return_value=json.dumps(sample)):
                with self.assertRaisesRegex(ValueError, "Unsupported image metadata"):
                    builder.image_info(Path("fixture.qcow2"), "qcow2")

    def test_synthetic_data_survives_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw, source, output = root / "disk.raw", root / "disk.qcow2", root / "disk.vhdx"
            with raw.open("wb") as stream:
                stream.truncate(16 * 1024 ** 2)
                stream.seek(10 * 1024 ** 2 + 189)
                stream.write(b"fixture located beyond the first virtual block")
            subprocess.run(["qemu-img", "convert", "-f", "raw", "-O", "qcow2",
                            str(raw), str(source)], check=True)
            result = builder.convert(source, output)
            self.assertEqual(result["outputVirtualBytes"], raw.stat().st_size)
            self.assertEqual(result["sha256"], builder.digest(output))
            subprocess.run(["qemu-img", "compare", "-q", "-f", "raw", "-F", "vhdx",
                            str(raw), str(output)], check=True)
            with self.assertRaises(FileExistsError):
                builder.convert(source, output)


if __name__ == "__main__":
    unittest.main()
