# 已知问题

截至 2026-10-01，内核 6.18.54-l410，Debian forky（Plasma 6.7.4，Mesa 26.1.6）。

## 没做的硬件

| 部件 | 情况 |
|---|---|
| DP / HDMI 输出 | **已完成（拼图 2）**：DRM KMS 驱动 `kirin990_dp` + RTD2172，激活外接双屏扩展显示（实机验证通过，消除 SError 与 KMS 托管 encoder 异常） |
| 指纹识别 | **已完成（拼图 4）**：iTrustee TEE 网关 `tzdriver` + 平台驱动 `huawei-fingerprint` + 用户态服务栈（已对齐麒麟 990 18 槽单页 TEEOS 队列布局） |
| 硬件视频编码 | **已完成（拼图 1）**：`hisi-venc` V4L2 状态式 mem2mem 驱动已合并，实机 480 MHz / IRQ 161 成功点亮绑定，支持 H.264/HEVC 硬件编码 |
| Vulkan | **已完成（拼图 3）**：Mesa 开源 `panvk` 已支持 Mali-G76 (Bifrost v7) Vulkan 1.3 硬件加速 |
| 风扇转速 | 风扇完全由 EC 根据板上热敏电阻控制，厂商系统里也没有驱动，读不到转速 |
| KVM | 固件只给 EL1，没有 EL2，不能用虚拟化 |
| USB OTG、Type-C PD、充电器类型识别 | 暂未实现 |

## 已知缺陷

- 看门狗（v6.18.54-l410.1 已修）：固件在进内核前已经启动 AP 看门狗 WDT0（SP805，0xfe026000），交给内核时约剩 60 s，中断经 BL31 转成 FIQ。
  v6.18.54-l410 带 `l410_deadman=0` 启动会在开机约 60 s 时 panic（"FIQ taken without a root FIQ handler"）。v6.18.54-l410.1 的内核开机就接管并停掉它。
  为了让旧版内核也能用，`boot/install-kernel.sh` 仍会去掉 `l410_deadman=0`，`system/hardware/l410-watchdog-off.service` 开机后再停一次，对新内核没有影响。
- 睡眠：s2idle 正常（默认）。键盘唤醒与开盖唤醒已通过 `09-laptop.dtsi` 设备树修补补充 `wakeup-source;` 属性彻底解决（拼图 0），实测按键/开盖即醒。
  deep（经 LPM3 的挂起）能睡下去，但唤醒后整机冷启动，所以没用它。s2idle 的耗电还没测；挂起期间没有网络唤醒。
  Plasma 6.7 在 RTC 闹钟这类非用户触发的唤醒之后会自动再睡，这是 PowerDevil 的设计。
  见 [hardware/sleep.md](hardware/sleep.md)。
- 显示：`kirin990_drm.power_off=4`（关屏时连 vivobus/media1 一起断电）会让整机在约 1 秒后挂死，原因未知，默认用 3。
- UFS：`rpm_lvl=5`（运行时让器件断电）恢复后第一次 auto-hibern8 退出会失败一次，170 ms 后自动恢复。默认的 `rpm_lvl=1` 碰不到。
- WiFi：开机校准偶尔要 9 秒；蓝牙串口（BUART）走 PIO，没有 DMA；驱动不能卸载；PCIe RC1 一旦 completion timeout 不会自己恢复。
  NetworkManager 每次连接时第一次 connect 会被拒，重扫后成功，多花约 1 秒。
- 音频：耳机插拔和线控需要人工验证；每次时钟启停后功放会锁存一个时钟错误位（不影响出声）；
  流开始时功放比 I2S 时钟早约 10 ms 上电（声音是淡入的，听不出来）。
  **功放有板型差异**：`KLVU-WDU0B` 是 TAS2562（I2C 0x4c/0x4e），`KLVU-WDU0` 是 CS35L36（0x50/0x52）。6.18 两种都支持，card 按实际 probe 成功的那一对创建扬声器 link；当前远程 `L410 KLVU-WDU0` 的 CS35L36 已实测出声。CS35L36 的内部 PLL 可能显示未锁定，只打在 debug 级别。见 [hardware/audio.md](hardware/audio.md)。
- Chromium：在信息流很重的网页（例如 bilibili 首页）上极快滚动约 49 到 50 fps。原因在网页自己的主线程
  （追加卡片时 85 到 290 ms 的布局、长 JS 定时器），以及 Chromium 的 Wayland 帧回调节流；合成器和 GPU 都有余量。
  Firefox 在同样的页面上 58 到 60 fps。见 [tuning/desktop.md](tuning/desktop.md)。
- 视频硬解（v6.18.54-l410.2 起）：Chromium 只硬解 8 bit（H.264、HEVC Main、VP8、VP9 profile 0），VP9 profile 2 回退软解，
  HEVC 10 bit 在 Chromium 里放不了。Chromium 的 VA-API 路径是绿屏，所以用它自带的 V4L2 解码器；Firefox 没有硬解。
  VA-API 驱动 libva-v4l2-request 销毁上下文时会丢掉还没取走的帧。见 [hardware/vcodec.md](hardware/vcodec.md)。
- 应用启动：QQ 和 Firefox 的冷启动只比原来快 1.4 到 1.7 倍，剩下的是它们自己主线程的初始化。
- sched_ext：lavd 下温控（IPA）降频比 EAS 温和；bilibili 的渲染主线程在 lavd 下有一半时间跑在 A55 上。
- 2026-10-01 晚上的桌面画面黑屏崩溃：已查明原因，为外接 DP TX 在电源域与时钟未打开时提前被读取触发不可屏蔽的 CPU SError 异常中断，现已通过电源时序门控彻底修复。另一次网络 ssh 不响应已确认恢复。

## 维护上要注意

- 本地编译的几个库跟着 Debian 的包版本走：
  - Mesa 升级后，`/usr/local/lib/l410-mesa` 里的 libgallium 文件名对不上就不再被加载（apt 钩子会提示），要用 `system/mesa/build.sh` 重编；
  - libinput10 升级后，apt 钩子把旧的补丁版移开，滚动加速失效，重跑 `system/input/install.sh`；
  - `/usr/local/bin/systemsettings`（常驻版）没有 apt 钩子，Plasma 升级后要用 `system/launch/systemsettings-build.sh` 重编，否则删掉它；
  - WPS 的 RSA 垫片依赖 WPS 自带 libcrypto 的 `RSA_get0_*` 接口，WPS 大版本升级后要验证。
- RTC 存的是本地时间（和麒麟共用）。只装 Debian 时可以 `timedatectl set-local-rtc 0` 改回 UTC。
- 内核配置里打开了 AppArmor、Landlock 等安全选项（`97-security-net.config`），Debian 的 AppArmor 配置是启用的。

## 试过但不要再试

- 往 KWin 里 LD_PRELOAD 库：kwin_wayland 带文件能力（AT_SECURE），只能预加载系统目录里的 setuid 库，而这样的库任何用户都能拿去预加载进 sudo，等于本地提权。
- `kirin990_drm.power_off=4`：见上。
- 功放 IDC 滞回设成 0xffffffff：功放完全无声。提前或在流中途切换 `S4_IF_TX_ENA`：帧时钟不稳，功放报 52 ms 时钟错误后停机。
- 把 KWin 的帧预测换成「均值 + 3 倍标准差」：Chromium 和 Firefox 都变差。
