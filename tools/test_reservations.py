import platform
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64", "needs native Apple arm64")
class ReservationBoundsTests(unittest.TestCase):
    def test_reserve_helper_reports_mapped_bounds_and_preserves_callers(self):
        root = Path(__file__).resolve().parents[1]
        (root / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root / "build") as directory:
            directory = Path(directory)
            for key in ("SHIMBoundedReservations", "SHIMShrinkReservations", None):
                with self.subTest(key=key):
                    plist = directory / "Info.plist"
                    plist.write_bytes(plistlib.dumps({key: True} if key else {}))
                    binary = directory / "test-reservations"
                    subprocess.run([
                        "xcrun", "-sdk", "macosx", "clang", "-arch", "arm64", "-O2",
                        "-fobjc-arc", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                        str(root / "tools/test_reservations.m"), "-o", str(binary),
                        "-Wl,-sectcreate,__TEXT,__info_plist," + str(plist),
                    ], check=True)
                    result = subprocess.run([str(binary), "enabled" if key else "disabled"],
                                            capture_output=True, text=True, cwd=root)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    print(f"{key or 'disabled'}: {result.stdout.strip()}")


if __name__ == "__main__":
    unittest.main()
