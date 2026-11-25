# 分析 xiugou_tv.exe 的 minidump：异常线程调用栈 + 每帧所属模块。
# 用法: python tool/analyze_dump.py <dump_path>
import struct
import sys

from minidump.minidumpfile import MinidumpFile


def main(path):
    md = MinidumpFile.parse(path)
    exc = md.exception.exception_records[0]
    print('=== Exception ===')
    print('thread id :', hex(exc.ThreadId))
    print('code      :', exc.ExceptionRecord.ExceptionCode)
    print('addr      :', hex(exc.ExceptionRecord.ExceptionAddress))
    info = exc.ExceptionRecord.ExceptionInformation
    if info:
        print('param[0]  :', info[0])

    # x64 CONTEXT: Rip @ 0xF8, Rsp @ 0x98。
    with open(path, 'rb') as f:
        f.seek(exc.ThreadContext.Rva)
        ctx = f.read(exc.ThreadContext.DataSize)
    rip, rsp = struct.unpack_from('<Q', ctx, 0xF8)[0], struct.unpack_from('<Q', ctx, 0x98)[0]
    print('=== Context (x64) ===')
    print('rip:', hex(rip), ' rsp:', hex(rsp))

    modlist = md.modules.modules

    def owner(addr):
        for m in modlist:
            if m.baseaddress <= addr < m.baseaddress + m.size:
                return m
        return None

    print('=== Modules (base..end) name ===')
    for m in modlist:
        print(f'{m.baseaddress:016x}-{m.baseaddress + m.size:016x}  {m.name}')

    print('=== Stack scan (rsp..+256KB) ===')
    reader = md.get_reader()
    # 按内存段逐段读，避免跨界报错。
    segs = sorted(
        [r for r in reader.memory_segments if r.end_virtual_address > rsp],
        key=lambda r: r.start_virtual_address,
    )
    values = []  # (rsp_offset, qword)
    cursor = rsp
    total = 0
    for r in segs:
        if r.start_virtual_address > cursor:
            break  # 栈不连续，到这里即可。
        start = max(cursor, r.start_virtual_address)
        size = min(r.end_virtual_address - start, 0x40000 - total)
        if size <= 0:
            break
        try:
            buf = reader.read(start, size)
        except Exception:
            break
        for off in range(0, len(buf) - 8, 8):
            (val,) = struct.unpack_from('<Q', buf, off)
            values.append(((start + off) - rsp, val))
        total += size
        cursor = start + size
        if total >= 0x40000:
            break
    count = 0
    for rel, val in values:
        m = owner(val)
        if m is not None:
            print(f'rsp+{rel:05x}  {val:016x}  {m.name}  +{val - m.baseaddress:#x}')
            count += 1
            if count > 60:
                break


if __name__ == '__main__':
    main(sys.argv[1])
