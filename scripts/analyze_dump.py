#!/usr/bin/env python3
"""最小化的 minidump 解析器：提取异常信息、崩溃线程寄存器、模块列表，
并对栈内存做模块级调用链扫描（无需 pdb 符号）。"""
import struct, sys

DUMP = r"C:\crashdumps\xiugou_tv.exe.4252.dmp"

# minidump 流类型
ST_EXCEPTION      = 0x0006
ST_MODULELIST     = 0x0004
ST_SYSTEMINFO     = 0x0007
ST_MEMORY64LIST   = 0x0009
ST_MEMORYLIST     = 0x0005

class Reader:
    def __init__(self, path):
        self.f = open(path, "rb")
    def read(self, off, n):
        self.f.seek(off)
        b = self.f.read(n)
        if len(b) < n:
            raise IOError(f"read {n} @ {off} only got {len(b)}")
        return b

def u32(b, o=0): return struct.unpack_from("<I", b, o)[0]
def u64(b, o=0): return struct.unpack_from("<Q", b, o)[0]

def main():
    r = Reader(DUMP)
    hdr = r.read(0, 32)
    sig = hdr[:4]
    assert sig == b"MDMP", f"不是 minidump: {sig}"
    nstreams = u32(hdr, 8)
    dir_rva  = u32(hdr, 12)
    print(f"[*] minidump  签名={sig}  流数量={nstreams}  目录RVA=0x{dir_rva:X}")

    streams = {}
    for i in range(nstreams):
        ent = r.read(dir_rva + i*12, 12)
        stype = u32(ent, 0)
        dsize = u32(ent, 4)
        rva   = u32(ent, 8)
        streams[stype] = (rva, dsize)

    modules = []  # (base, size, name)
    if ST_MODULELIST in streams:
        rva, ds = streams[ST_MODULELIST]
        cnt = u32(r.read(rva, 4), 0)
        off = rva + 4
        for _ in range(cnt):
            mraw = r.read(off, 72)
            base = u64(mraw, 0)
            size = u32(mraw, 8)
            name_rva = u32(mraw, 20)
            nstr = r.read(name_rva, 4)
            nlen = u32(nstr, 0)
            nm = r.read(name_rva+4, nlen).decode("utf-16-le", "replace")
            modules.append((base, size, nm))
            off += 108
        modules.sort()
        print(f"[*] 模块总数: {len(modules)}")

    # 系统信息
    arch = "?"
    if ST_SYSTEMINFO in streams:
        rva, ds = streams[ST_SYSTEMINFO]
        sinfo = r.read(rva, min(ds, 48))
        pa = u16 = None
        arch_code = u16_v = struct.unpack_from("<H", sinfo, 0)[0]
        # ProcessorArchitecture 在偏移 0 (u16)
        arch_map = {0:"x86",5:"ARM",9:"AMD64(x64)",12:"ARM64"}
        arch = arch_map.get(arch_code, str(arch_code))
        # OS 版本在偏移 0x10 (major u32), 0x14 (minor u32)
        osmaj = u32(sinfo, 0x10) if len(sinfo)>=0x18 else 0
        osmin = u32(sinfo, 0x14) if len(sinfo)>=0x18 else 0
        print(f"[*] 处理器架构: {arch}  OS版本: {osmaj}.{osmin}")
    else:
        print("[*] 无 SystemInfo 流")

    # 异常流
    exc = None
    if ST_EXCEPTION in streams:
        rva, ds = streams[ST_EXCEPTION]
        eraw = r.read(rva, ds)
        thread_id = u32(eraw, 0)
        # 流布局: offset0 ThreadId(u32), 4 align(u32), 8 起 MINIDUMP_EXCEPTION
        # MINIDUMP_EXCEPTION: 0 code(u32),4 flags(u32),8 record(u64),16 address(u64),
        #   24 numparams(u32),28 unused(u32),32 info[15*8]
        # 末尾 8 字节是 ThreadContext: DataSize(u32)@160, RVA(u32)@164
        exc_code  = u32(eraw, 8)
        exc_addr  = u64(eraw, 24)
        nump      = u32(eraw, 32)
        # ExceptionInformation: info[0]=访问类型(0读/1写/8执行), info[1]=触发违规的虚拟地址
        if nump >= 2:
            acc = u64(eraw, 40)
            fault_va = u64(eraw, 48)
            acc_kind = {0:"读(READ)",1:"写(WRITE)",8:"执行(EXECUTE)"}.get(acc, str(acc))
            print(f"[*] 访问违规类型: {acc_kind}  触发地址 VA=0x{fault_va:016X}")
        ctx_size  = u32(eraw, 160)
        ctx_rva2  = u32(eraw, 164)
        print(f"[*] 崩溃线程 ID: {thread_id}")
        print(f"[*] 异常码: 0x{exc_code:08X}", end="")
        code_map = {0xc0000409:"STATUS_STACK_BUFFER_OVERRUN(__fastfail)",
                    0xc0000005:"STATUS_ACCESS_VIOLATION",
                    0xc000041d:"STATUS_FAIL_FAST_EXCEPTION",
                    0xc0000374:"STATUS_HEAP_CORRUPTION"}
        if exc_code in code_map: print(f"  ({code_map[exc_code]})", end="")
        print()
        print(f"[*] 异常地址: 0x{exc_addr:016X}")
        exc = (exc_addr, ctx_rva2, ctx_size, thread_id)
    else:
        print("[!] 无 Exception 流")

    def module_of(addr):
        for base, size, nm in modules:
            if base <= addr < base + size:
                return (base, size, nm, addr - base)
        return None

    if exc:
        m = module_of(exc[0])
        if m:
            print(f"    -> 落在模块: {m[2]}  模块内偏移=0x{m[3]:X}")
        else:
            print("    -> 未映射到任何已加载模块（可能在栈/堆/未加载）")

    # 读取崩溃线程上下文 (AMD64)
    if exc and arch.startswith("AMD64"):
        crva, csize = exc[1], exc[2]
        if crva and csize:
            cbuf = r.read(crva, csize)
            # CONTEXT_AMD64 偏移: Rsp=0x98, Rip=0xF8
            rip = u64(cbuf, 0xF8)
            rsp = u64(cbuf, 0x98)
            rbp = u64(cbuf, 0xA0)
            print(f"[*] 上下文 RIP=0x{rip:016X}  RSP=0x{rsp:016X}  RBP=0x{rbp:016X}")
            # 故障指令字节
            ibytes = read_va(rip, 16)
            if ibytes:
                print(f"[*] 故障指令字节(16): {ibytes.hex()}")
                try:
                    import capstone
                    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
                    for ins in md.disasm(ibytes, rip):
                        print(f"    反汇编: 0x{ins.address:X}: {ins.mnemonic} {ins.op_str}")
                        break
                except Exception as ex:
                    print(f"    (无 capstone 反汇编: {ex})")
            rm = module_of(rip)
            if rm: print(f"    RIP 模块: {rm[2]}  偏移=0x{rm[3]:X}")

            # 解析内存映射 (Memory64List): 各段数据在文件中是连续存放的
            mem_ranges = []  # (start_va, size, file_offset)
            base_rva = 0
            if ST_MEMORY64LIST in streams:
                mrva, mds = streams[ST_MEMORY64LIST]
                mh = r.read(mrva, 16)
                nrange = u64(mh, 0)
                base_rva = u64(mh, 8)
                roff = mrva + 16
                cum = 0
                for _ in range(nrange):
                    d = r.read(roff, 16)
                    sv = u64(d, 0)
                    sz = u64(d, 8)
                    mem_ranges.append((sv, sz, base_rva + cum))
                    cum += sz
                    roff += 16
                print(f"[*] 内存段数量(Memory64List): {nrange}")
            # 内存读取: VA -> 文件偏移（累进偏移）
            def read_va(va, n):
                for sv, sz, fo in mem_ranges:
                    if sv <= va < sv + sz:
                        return r.read(fo + (va - sv), n)
                return None
            # 测试能否读到崩溃线程的栈
            test = read_va(rsp, 16)
            if test is None:
                print("    [!] 警告: RSP 所在内存段未在 dump 中 (栈未被捕获)")
            else:
                print("    [+] 栈内存可读")
            # 模块级栈扫描
            print("\n[*] 栈内存模块级调用链 (从 RSP 向上，模块粒度):")
            stack = read_va(rsp, 0x6000)
            chain = []
            last = None
            if stack:
                for i in range(0, len(stack)-8, 8):
                    val = u64(stack, i)
                    mm = module_of(val)
                    if mm:
                        tag = f"{mm[2]} +0x{mm[3]:X}"
                        if tag != last:
                            chain.append((val, mm[2], mm[3]))
                            last = tag
                # 打印，最多 40 个、去重后仍显示序列
                shown = 0
                for val, nm, off in chain:
                    print(f"    0x{val:016X}  {nm}  +0x{off:X}")
                    shown += 1
                    if shown >= 40:
                        print("    ...(截断)")
                        break
                if not chain:
                    print("    (栈上未识别到模块地址，可能 unwind 信息缺失)")
            else:
                print("    (无法读取栈内存)")

    # 打印关键模块
    print("\n[*] 关键视频/引擎相关模块:")
    keys = ["flutter","mpv","media","video","av","sw","dxva","d3d","nv","libmpv","opengl","egl"]
    for base, size, nm in modules:
        low = nm.lower()
        if any(k in low for k in keys):
            print(f"    0x{base:016X}  size=0x{size:X}  {nm}")

if __name__ == "__main__":
    main()
