@echo off
REM ============================================================
REM 修狗TV 对照启动器 —— ANGLE SwiftShader（软件 GL）模式
REM 目的: 验证 "flutter_windows.dll 解引用 NULL surface" 崩溃
REM       是否由硬件 D3D11 设备创建失败（nvlddmkm / AVHWDeviceContext）
REM       导致。SwiftShader 用纯软件 GL，不依赖硬件 D3D 设备。
REM
REM 用法: 双击本文件，或在项目根目录命令行执行。
REM 注意: 当前 Flutter 3.44.9 的 Windows embedder 不暴露 engine
REM       switches 字段，无法在代码里内置该参数，故用启动器注入。
REM ============================================================
setlocal
set "RELEASE_DIR=%~dp0..\build\windows\x64\runner\Release"
if not exist "%RELEASE_DIR%\xiugou_tv.exe" (
  echo [错误] 未找到 Release 构建: %RELEASE_DIR%\xiugou_tv.exe
  echo 请先执行: flutter build windows
  pause
  exit /b 1
)
cd /d "%RELEASE_DIR%"

REM 关键: 让 ANGLE 强制使用软件 GL 后端 (SwiftShader)，
REM 绕过硬件 D3D11 设备创建失败 -> 避免 surface 为 NULL。
set ANGLE_DEFAULT_PLATFORM=swiftshader

echo [对照] 以软件 GL (SwiftShader) 启动 xiugou_tv.exe ...
echo [对照] 参数: --use-angle=swiftshader + 环境变量 ANGLE_DEFAULT_PLATFORM=swiftshader
echo [对照] 请在 App 内把"设置 -> 解码方式"切到"软件解码"，
echo [对照] 然后播放（点播或 CCTV4 直播）观察是否还会闪退。
echo.
xiugou_tv.exe --use-angle=swiftshader
endlocal
