#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {
// window_manager 的 TitleBarStyle.hidden 在 WM_NCCALCSIZE 里给左 / 右 / 下
// 各预留 8px 非客户区边框（所以这三边有 resize 命中），但 Win11 上顶部是
// top += 0，顶边被判为客户区、没有拖拽光标。这里用同样的固定 8px 给顶部
// 补齐边框；不按 DPI 缩放以免四边宽度不齐。
constexpr int kTopResizeBorder = 8;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  native_playback_.reset();
  if (webdav_secrets_channel_) {
    webdav_secrets_channel_->SetMethodCallHandler(nullptr);
    webdav_secrets_channel_.reset();
  }
  // S48: safety net. ~unique_ptr does not null the pointer before deleting,
  // so messages arriving during teardown would reach a half-destroyed
  // controller; reset() nulls first, so MessageHandler sees nullptr.
  flutter_controller_.reset();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // 自绘标题栏（window_manager 的 TitleBarStyle.hidden）：去掉系统标题栏
  // 样式位，避免我们在 WM_NCCALCSIZE 给顶部预留边框后，DWM 把那条边框当成
  // 系统标题栏而画出最小化 / 最大化 / 关闭按钮。保留 WS_THICKFRAME 让四边
  // 仍有原生 resize 边框与命中。
  {
    HWND hwnd = GetHandle();
    LONG style = ::GetWindowLong(hwnd, GWL_STYLE);
    style &= ~(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
    style |= WS_THICKFRAME;
    ::SetWindowLong(hwnd, GWL_STYLE, style);
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                       SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto* engine = flutter_controller_->engine();
  native_playback_ = std::make_unique<native_playback::PlaybackChannel>(
      engine->messenger(), engine->GetRegistrarForPlugin("XiugouNativePlayback"), engine, GetHandle());
  process_job_channel_ =
      RegisterProcessJobChannel(flutter_controller_->engine()->messenger());
  webdav_secrets_channel_ =
      RegisterWebDavSecretsChannel(flutter_controller_->engine()->messenger());
  fullscreen_ = std::make_unique<WindowFullscreen>(GetHandle());
  fullscreen_channel_ = RegisterWindowFullscreenChannel(
      flutter_controller_->engine()->messenger(), fullscreen_.get());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Drop the channel before the engine it is bound to.
  native_playback_.reset();
  if (webdav_secrets_channel_) {
    webdav_secrets_channel_->SetMethodCallHandler(nullptr);
    webdav_secrets_channel_.reset();
  }
  process_job_channel_ = nullptr;
  fullscreen_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // §52：全屏期间的 WM_NCCALCSIZE 必须先于 window_manager 插件处理。
  if (fullscreen_) {
    if (auto handled = fullscreen_->HandleMessage(message, wparam, lparam)) {
      return *handled;
    }
  }

  if (message == WM_TIMER && native_playback_ && native_playback_->HandleTimer(wparam)) return 0;

  // Give Flutter, including plugins, an opportunity to handle window messages.
  // WM_NCCALCSIZE 延后返回：需要在插件算好的客户区基础上补顶部边框。
  std::optional<LRESULT> plugin_result;
  if (flutter_controller_) {
    plugin_result = flutter_controller_->HandleTopLevelWindowProc(
        hwnd, message, wparam, lparam);
    if (plugin_result && !(message == WM_NCCALCSIZE && wparam)) {
      return *plugin_result;
    }
  }

  // 顶部边缘补齐 resize 命中：插件对 hidden 标题栏在 Win11 上不预留顶部
  // 非客户区（左右下各 8px，top += 0），顶边因此被判为客户区、没有双向箭头，
  // 也无法拖动调整高度。这里在插件结果之上把顶部也预留同样的边框，交给系统
  // 的 DefWindowProc 提供 HTTOP。样式位已在 OnCreate 去掉系统按钮，所以不会
  // 再冒出标题栏 / 菜单。最大化 / 全屏跳过：最大化时插件已自行预留顶部，
  // 全屏由 fullscreen_ 先行接管。
  if (message == WM_NCCALCSIZE && wparam && fullscreen_ &&
      !fullscreen_->IsFullScreen() && !::IsZoomed(hwnd)) {
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    params->rgrc[0].top += kTopResizeBorder;
    return plugin_result.value_or(0);
  }

  if (plugin_result) {
    return *plugin_result;
  }

  switch (message) {
    case WM_FONTCHANGE:
      // S48: the controller may already be released during teardown.
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
