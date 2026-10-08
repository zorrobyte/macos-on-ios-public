import struct
import tempfile
import unittest
from pathlib import Path

from macho import align_string_pool


class StringPoolAlignmentTests(unittest.TestCase):
    def binary(self, stroff=164, gap=4):
        pool = b"\0hello\0\0"
        signature = stroff + len(pool) + gap
        data = bytearray(signature + 16)
        struct.pack_into("<8I", data, 0, 0xfeedfacf, 0x100000c, 0, 6, 3, 112, 0, 0)
        struct.pack_into("<II16sQQQQIIII", data, 32,
                         0x19, 72, b"__LINKEDIT", 0, 4096, 144, len(data) - 144, 1, 1, 0, 0)
        struct.pack_into("<6I", data, 104, 2, 24, 144, 0, stroff, len(pool))
        struct.pack_into("<4I", data, 128, 0x1d, 16, signature, 16)
        data[stroff:stroff + len(pool)] = pool
        data[signature:] = b"S" * 16
        return data, stroff, pool, signature

    def repair(self, data):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / "test.dylib"
        path.write_bytes(data)
        return path

    def test_misaligned_linkedit_string_pool_preserves_contents_and_signature(self):
        data, stroff, pool, signature = self.binary()
        path = self.repair(data)
        self.assertTrue(align_string_pool(path))
        result = path.read_bytes()
        self.assertEqual(struct.unpack_from("<I", result, 120)[0], stroff + 4)
        self.assertEqual(result[stroff + 4:stroff + 4 + len(pool)], pool)
        self.assertEqual(result[signature:], data[signature:])
        expected = bytearray(data)
        struct.pack_into("<I", expected, 120, stroff + 4)
        expected[stroff:signature] = bytes(4) + pool
        self.assertEqual(result, expected)
        self.assertFalse(align_string_pool(path))

    def test_aligned_pool_is_unchanged(self):
        data, *_ = self.binary(stroff=168, gap=0)
        path = self.repair(data)
        self.assertFalse(align_string_pool(path))
        self.assertEqual(path.read_bytes(), data)

    def test_insufficient_padding_is_rejected_without_writing(self):
        data, *_ = self.binary(gap=0)
        path = self.repair(data)
        with self.assertRaises(ValueError):
            align_string_pool(path)
        self.assertEqual(path.read_bytes(), data)

    def test_nonzero_padding_is_rejected_without_writing(self):
        data, _, _, signature = self.binary()
        data[signature - 1] = 1
        path = self.repair(data)
        with self.assertRaises(ValueError):
            align_string_pool(path)
        self.assertEqual(path.read_bytes(), data)

    def test_truncated_commands_are_rejected(self):
        data, *_ = self.binary()
        path = self.repair(data[:100])
        with self.assertRaises(ValueError):
            align_string_pool(path)


if __name__ == "__main__":
    unittest.main()
