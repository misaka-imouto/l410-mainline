# 电源键指纹识别与 TrustZone 安全子系统

华为擎云 L410 笔记本配备了与电源键集成的电容式指纹传感器（Power-button Fingerprint Sensor）。
在架构设计上，为了满足高安全级别的生物特征保护规范，麒麟 990 平台采用了 ARM TrustZone 硬件安全隔离方案，指纹采集与特征比对完全在安全世界（Secure World）内闭环完成。

在 Linux 6.18 主线内核中，我们通过引入 **iTrustee tzdriver** 安全客户端网关驱动与 **huawei-fingerprint** 平台驱动，完整打通了从内核设备节点、TrustZone 通信通道到用户态守护进程与桌面 PAM 生物认证的完整技术栈。

---

## 1. 硬件拓扑与引脚定义

传感器由 Fingerprint Cards AB (FPC) 制造，属于 FPC1020/1025 系列芯片架构（硬件识别码 `0x204`，内核平台代号 `taurus`）：

| 引脚功能 | SoC 控制器 / 引脚 | 硬件中断 / 编号 | 说明 |
|---|---|---|---|
| **SPI 传输总线** | SPI1 (`0xfa048000`) | N/A | **隔离至 Secure World**，仅供 TEE OS 读写 |
| **复位控制 (RST)** | `fa8b7000.gpio` pin 1 | GPIO 199 (全局 281) | 传感器硬件复位与低功耗控制 |
| **按压中断 (IRQ)** | `fa8b1000.gpio` pin 2 | GPIO 234 (IRQ 205) | 手指轻触/按压唤醒中断信号 |
| **片选控制 (CS)** | GPIO 10 | N/A | SPI 传输片选 |

固件设备树（Device Tree）中已预置对应的硬件描述节点：
```dts
fingerprint {
    compatible = "fpc,fingerprint";
    fingerprint,reset_gpio = <0xc7>;      /* GPIO 199 */
    fingerprint,irq_gpio = <0xea>;        /* GPIO 234 */
    fingerprint,cs_gpio = <0x0a>;         /* GPIO 10 */
    fingerprint,spi_bus = <0x01>;         /* SPI 1 */
    fingerprint,sensor_type = <0x204>;    /* FPC1020/1025 */
    status = "ok";
};
```

---

## 2. TrustZone 隔离架构与安全设计

擎云 L410 的指纹生物识别系统在软硬件各层级严格遵循非安全世界（Normal World / REE）与安全世界（Secure World / TEE）物理隔离设计：

```
+------------------------------------------------------------------------+
|                      Normal World (Linux 6.18 REE)                     |
|                                                                        |
|  [ Desktop Login / PAM / Sudo ]                                        |
|               |                                                        |
|  [ deepin-authenticate / DBus: com.huawei.Fingerprint ]                |
|               |                                                        |
|     [ fingerprint_daemon ]                                             |
|        /              \                                                |
|   [ teecd ]       /dev/fingerprint                                     |
|       |           (GPIO 199 RST 上电, GPIO 234 IRQ 触摸捕获)           |
|  /dev/tc_ns_client                                                     |
+-------|----------------------------------------------------------------+
|       | SMC 0xC3000000+                                                |
+-------v----------------------------------------------------------------+
|                      Secure World (iTrustee TEE)                       |
|                                                                        |
|  [ BL31 ATF (EL3) ] -> [ iTrustee Secure OS (S-EL1 BL32) ]             |
|                                     |                                  |
|            [ Huawei TA: a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec ]     |
|                                     |                                  |
|            [ SPI1 Secure Controller (0xfa048000) ]                     |
|                                     |                                  |
|            [ FPC Capacitive Sensor Hardware in Power Button ]          |
+------------------------------------------------------------------------+
```

### 为什么 Linux 内核不能直接读写 SPI1 寄存器？
在主流移动与桌面终端的高级安全体系中，指纹图像属于高敏感个人生物特征：
- 若 SPI 控制器挂载在 REE（Linux 内核），任何 root 权限程序或内核提权漏洞均可 dump 出原始指纹图像；
- L410 的硬件在启动时，ATF 固件将 SPI1 控制器（`fa048000`）配置为安全总线，非安全世界访问会直接触发外部总线异常（Asynchronous External Abort）；
- 只有经过华为私钥签名的安全应用（TA: `a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec`）才能在 iTrustee TEE 环境中配置 SPI1 并读取原始指纹数据，在隔离内存中完成加密和特征比对，比对结果仅以 Token 方式返回给非安全世界。

---

## 3. 内核驱动架构与 Linux 6.18 LTS 适配

为支撑完整的生物认证协议栈，`linux-l410` 内核引入了两个专用驱动模块：

### 3.1 iTrustee tzdriver (`drivers/tee/itrustee/`)
- **配置项**：`CONFIG_TZDRIVER=m`（模块化编译，随用户态 `teecd` 启动时序加载）。
- **功能**：基于 openEuler iTrustee 项目移植，实现非安全世界与 S-EL1 TEE 之间的 SMC 通信桥梁。
- **Linux 6.18 现代化适配**：
  1. 修复了旧版头文件中私自宏定义 `DECLARE_BITMAP` 导致覆盖 6.18 内核标准宏、引发设备结构体破坏的严重隐患；
  2. 修复 `core/shared_mem.c` 中 64 位整数与指针类型转换时的严格类型警告；
  3. 修复 `smc_smp.c` 中 `kthread_create_worker` 创建 `ipihelper` 线程的现代化 API 兼容性；
  4. **严格对齐麒麟 990 固件规格**：剔除源自云服务器的 `CONFIG_BIG_SESSION`，将 `struct tc_ns_smc_queue` 严格限定在单页（4KB 内、18 个槽位），使得物理命令队列字段与麒麟 990 出厂 TEEOS 固件完全吻合；
  5. 支持 `/dev/tc_ns_client` 字符设备节点创建与安全会话管理。

### 3.2 Huawei Fingerprint 驱动 (`drivers/misc/huawei-fingerprint/`)
- **配置项**：`CONFIG_HUAWEI_FINGERPRINT=m`。
- **功能**：
  1. 匹配 `fpc,fingerprint` 设备树节点；
  2. 控制 GPIO 199 信号线输出高低电平，完成 FPC 芯片上电与复位序列；
  3. 注册 GPIO 234 双边沿触发中断，在用户轻触电源键时产生 IRQ，通过 waitqueue 与 `sysfs_notify` 唤醒非安全世界等待进程；
  4. 导出 `/dev/fingerprint` 字符设备，并实现标准 ioctl 接口（`FP_IOC_CMD_GET_DEVICE_INFO`、`FP_IOC_CMD_ENABLE_IRQ` 等）；
  5. 提供 `/sys/class/huawei_fp/fingerprint/` 状态监控接口。

---

## 4. 用户态服务栈与系统配置

用户态服务由 [system/fingerprint/](../../system/fingerprint/)（`system/install.sh fingerprint`）统一管理：

### 4.1 设备权限规则 (`99-huawei-fingerprint.rules`)
```udev
KERNEL=="tc_ns_client", MODE="0666", GROUP="tee"
KERNEL=="fingerprint", MODE="0660", GROUP="input"
SUBSYSTEM=="huawei_fp", MODE="0660", GROUP="input"
```

### 4.2 核心服务说明
1. **`teecd.service`**：
   - 命令：`/vendor/bin/teecd`
   - 加载位于 `/system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec` 的指纹 TA 到安全世界，并监听安全会话事件。
2. **`hwfp_init.service`**：
   - 命令：`/usr/bin/fingerprint_daemon`
   - 监听 `/dev/fingerprint` 中断，在检测到按压事件后与 TA 通信进行生物特征比对，并在系统总线上注册 `com.huawei.Fingerprint` DBus 服务。
3. **`deepin-authenticate.service` / Linux PAM**：
   - 将桌面系统的密码输入界面与指纹识别自动联动。支持锁屏唤醒即轻触电源键瞬时解锁。

---

## 5. 验证与诊断测试

系统提供了开箱即用的测试诊断工具：

```bash
# 1. 运行自检工具，确认驱动、设备节点、TA 与服务状态
system/fingerprint/test-fingerprint.sh

# 2. 实时按压监测：运行后轻触电源键指纹识别区域，验证硬件中断捕获
sudo system/fingerprint/test-fingerprint.sh --monitor
```

终端输出示例：
```
==========================================================
 Huawei Qingyun L410 Fingerprint Sensor Diagnostic Test
==========================================================
[PASS] /dev/tc_ns_client (iTrustee TEE SMC gateway) found: crw-rw-rw- 1 root tee
[PASS] /dev/fingerprint (Huawei platform driver) found: crw-rw---- 1 root input
[PASS] Sysfs class directory /sys/class/huawei_fp/fingerprint exists.
[INFO] Chip Info: 0x204
[INFO] Module ID: 0x204
[PASS] Huawei Fingerprint Secure World TA found: /system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec
[PASS] teecd process is running (PID: 789)
[PASS] fingerprint_daemon is running (PID: 852)
[PASS] DBus service 'com.huawei.Fingerprint' is active on system bus.
----------------------------------------------------------
Diagnostic complete: All essential components present.
```
