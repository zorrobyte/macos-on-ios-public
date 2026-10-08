"""Small layout repairs for thin arm64 binaries, before signing."""
import struct
from pathlib import Path


def align_string_pool(path):
    """Align LC_SYMTAB strings using trailing padding before the code signature.

    Return whether the file changed. Refuse layouts requiring other data to move.
    The caller must sign the modified binary again.
    """
    path = Path(path)
    data = bytearray(path.read_bytes())
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("expected a thin little-endian Mach-O 64 binary")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    end = 32 + sizeofcmds
    if end > len(data):
        raise ValueError("truncated Mach-O load commands")
    symtab = signature = linkedit = None
    offset = 32
    for _ in range(ncmds):
        if offset + 8 > end:
            raise ValueError("truncated Mach-O load command")
        cmd, size = struct.unpack_from("<II", data, offset)
        minimum = {2: 24, 0x1d: 16, 0x19: 72}.get(cmd, 8)
        if size < minimum or offset + size > end:
            raise ValueError("invalid Mach-O load command size")
        if cmd == 2:  # LC_SYMTAB
            symtab = offset
        elif cmd == 0x1d:  # LC_CODE_SIGNATURE
            signature = struct.unpack_from("<I", data, offset + 8)[0]
        elif cmd == 0x19 and data[offset + 8:offset + 24].rstrip(b"\0") == b"__LINKEDIT":
            linkedit = struct.unpack_from("<QQ", data, offset + 40)
        offset += size
    if symtab is None:
        return False
    stroff, strsize = struct.unpack_from("<II", data, symtab + 16)
    padding = -stroff % 8
    if not strsize or not padding:
        return False
    pool_end = stroff + strsize
    boundary = signature if signature is not None else len(data)
    # Only consume the alignment padding at the end of LINKEDIT's string pool.
    if (linkedit is None or stroff < max(end, linkedit[0])
            or boundary > min(len(data), sum(linkedit))
            or boundary != (pool_end + 7) // 8 * 8
            or pool_end + padding > boundary
            or any(data[pool_end:boundary])):
        raise ValueError(f"cannot align string pool using trailing padding: {path.name}")
    data[stroff + padding:pool_end + padding] = data[stroff:pool_end]
    data[stroff:stroff + padding] = bytes(padding)
    struct.pack_into("<I", data, symtab + 16, stroff + padding)
    path.write_bytes(data)
    return True
