"""解析 Windows minidump：异常码 + 崩溃线程调用栈（模块名 + 偏移）。

用法: python analyze_crash.py <dump...>

栈回溯从崩溃线程的 RSP/RBP 开始逐帧求解（x64 下用模块的导出符号与
RUNTIME_FUNCTION 不可得，故采用「扫描栈内存里落在 executable 模块内的
返回地址」的启发式方式，足够判断「死在哪一层」）。
"""
import sys
from minidump.minidumpfile import MinidumpFile

# Windows 控制台默认 GBK，脚本输出大量中文与十六进制，统一走 UTF-8
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

EXC_NAMES = {
    0xC0000005: "ACCESS_VIOLATION（访问冲突）",
    0xC000001D: "ILLEGAL_INSTRUCTION（非法指令）",
    0xC0000094: "INTEGER_DIVIDE_BY_ZERO（除零）",
    0xC00000FD: "STACK_OVERFLOW（栈溢出）",
    0xC0000409: "STACK_BUFFER_OVERRUN（/GS 栈保护被触发）",
    0x80000003: "BREAKPOINT（断点）",
    0xE06D7363: "CPP_EXCEPTION（C++ 异常）",
    0xC0000374: "HEAP_CORRUPTION（堆损坏）",
    0xC0000602: "FAIL_FAST_EXCEPTION（快速失败）",
    0xC00002B4: "FLOAT_MULTIPLE_FAULTS",
    0xC00000FF: "ABORT",
}

# 0xC0000409 的 ExceptionInformation[0] 是 «子代码»，取值见 MSDN
FAST_FAIL_SUBCODES = {
    0: "LEGACY_GS_VIOLATION",
    1: "VTGUARD_CHECK_FAILURE",
    2: "STACK_COOKIE_CHECK_FAILURE",
    3: "CORRUPT_LIST_ENTRY",
    4: "INCORRECT_STACK",
    5: "INVALID_ARGUMENT",
    6: "GS_COOKIE_INIT",
    7: "FATAL_APP_EXIT（abort() / __fastfail）",
    8: "RANGE_CHECK_FAILURE",
    9: "DEP_VIOLATION",
    10: "INVALID_CONTROL_FLOW_GUARD_TARGET",
}


def describe(mf):
    recs = mf.exception.exception_records
    if not recs:
        print("  (无异常记录)")
        return
    r = recs[0]
    er = r.ExceptionRecord
    # 库里的 ExceptionCode 是枚举，未知值会被吃掉；raw 字段才是真实数值
    code = int(getattr(er, "ExceptionCode_raw", 0) or 0)
    addr = int(er.ExceptionAddress)
    print(f"异常码: 0x{code:08X}  {EXC_NAMES.get(code, '未知')}")
    print(f"异常地址: 0x{addr:016X}")
    info = [int(er.ExceptionInformation[i])
            for i in range(int(getattr(er, "NumberParameters", 0) or 0))]
    if code == 0xC0000005 and len(info) >= 2:
        kind = {0: "读", 1: "写", 8: "执行"}.get(info[0], str(info[0]))
        print(f"访问类型: {kind}   违规地址: 0x{info[1]:016X}")
    elif code == 0xC0000409 and info:
        sub = info[0]
        print(f"快速失败子代码: {sub}  "
              f"{FAST_FAIL_SUBCODES.get(sub, '未知')}")
    print(f"崩溃线程: {r.ThreadId}")

    # 定位崩溃线程，从栈顶扫描返回地址
    threads = mf.threads.threads
    target = next((t for t in threads if t.ThreadId == r.ThreadId), None)
    if target is None:
        print("  (找不到崩溃线程)")
        return

    modules = []
    for m in mf.modules.modules:
        modules.append((m.baseaddress, m.baseaddress + m.size, m.name))

    def locate(va):
        for base, end, name in modules:
            if base <= va < end:
                return name, va - base
        return None

    hit = locate(addr)
    if hit:
        print(f"异常地址所属模块: {hit[0]}  (+0x{hit[1]:X})")

    # 读栈内存
    try:
        stack_start = target.Stack.StartOfMemoryRange
        stack_size = target.Stack.MemoryLocation.DataSize
        data = mf.get_reader().read(stack_start, stack_size)
    except Exception as e:
        print(f"  读取栈失败: {e}")
        return

    print("\n栈上返回地址（自上而下，最多 40 帧）:")
    seen = []
    for i in range(0, len(data) - 8, 8):
        va = int.from_bytes(data[i:i + 8], "little")
        h = locate(va)
        if h and va != addr:
            name, off = h
            frame = f"  {name:32s} +0x{off:X}"
            if frame not in seen:
                seen.append(frame)
            if len(seen) >= 40:
                break
    for f in seen:
        print(f)


def main(paths):
    for path in paths:
        print("=" * 78)
        print(path)
        try:
            mf = MinidumpFile.parse(path)
        except Exception as e:
            print(f"  解析失败: {e}")
            continue
        print(f"进程架构: {mf.sysinfo.ProcessorArchitecture}")
        describe(mf)
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
