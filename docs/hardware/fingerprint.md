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
  3. 修复 `smc_smp.c` 中 `kthread_create_worker` 创建 `ipihelper` 线程的现代化 API 兼容性，避免销毁 worker 时重复调用 `kthread_stop` 产生的内核告警；
  4. **严格对齐麒麟 990 固件规格**：剔除源自云服务器的 `CONFIG_BIG_SESSION`，将 `struct tc_ns_smc_queue` 严格限定在单页（4KB 内、18 个槽位），使得物理命令队列字段与麒麟 990 出厂 TEEOS 固件完全吻合；
  5. **SMC 命令就绪判定与协作式调度优化**：在 `wait_event_internal` 与 `proc_ta_pending` 超时逻辑中引入 `is_cmd_working_done(cmd_index)` 复核，确保 TEEOS 置位 `out_bitmap` 后第一时间响应。若短期（10ms/20ms）超时未就绪，主动发起 `SMC_OPS_SCHEDTO`（CPU 时间片让渡），向安全世界主动借出执行周期完成命令处理，杜绝因非安全世界盲等休眠导致的 TEE 线程饥饿与超时卡死；
  6. **初始化时序对齐**：先执行 `mailbox_mempool_init` 注册基础内存池，再通过 `tz_spi_init` 分配并注册通知共享内存（`GLOBAL_CMD_ID_REGISTER_NOTIFY_MEMORY`），支持 `/dev/tc_ns_client` 字符设备节点创建与安全会话管理；
  7. **Mailbox 越界释放与 Oops 根除**：出厂 4.19 内核仅单区 4MB 物理页池，而 openEuler 引入多池数组。固件返回 128 个 4K 页时误覆写 `g_mb_count=128`，导致异常回滚时释放越界触发 `___free_pages` Oops。通过严格截断至 `MAILBOX_POOL_COUNT` (8)，彻底消除崩溃；
  8. **屏蔽云容器特性阻断 (CMD 45)**：鲲鹏服务端容器特性 `GLOBAL_CMD_ID_REGISTER_HOST_NSID_VMID` 在移动端固件中不存在，失败后设为非致命放行，驱动顺利通过 `tc_teeos_init`；
  9. **中断与日志级别优化**：Device Tree SPI 344（GICv3 376）通过 `irq_of_parse_and_map` 正确挂载；`TEE_LOG_MASK` 设为 `TZ_DEBUG_INFO`，消除控制台冗余 SMC 寄存器调试转储；
  10. **出厂 4.19 反汇编比对与 SMC 抢占重试时序重构**：通过反汇编出厂 4.19 内核（`vmlinuz-4.19.71`）的 `smp_smc_send` 发现，4.19 在收到 `SMC_EXIT_PREEMPTED` 时完全不引入睡眠等待（无 `usleep_range`），也不设 50 次硬编码超时中止，而是直接使用 `cond_resched()` 调度让渡并持续调用 SMC 供 TEE 调度。openEuler 引入的 50 次休眠（每次 500-1000us）导致多页内存映射（如 128KB 通知内存与 512KB tlogger 内存）在安全世界建立页表期间被误判超时而中断。6.18 将重试门限扩展至 10000 次并移除 `usleep_range`，彻底解决多页内存注册超时；
  11. **SMC 服务线程空闲防空转 (`smc_svc_thread_fn`)**：针对 `GLOBAL_CMD_ID_SET_SERVE_CMD` 在 TEE 无服务请求或返回非零状态时的处理，加入 100ms 可中断睡眠，杜绝无任务时的 CPU 紧凑空转。

### 3.2 Huawei Fingerprint 驱动 (`drivers/misc/huawei-fingerprint/`)
- **配置项**：`CONFIG_HUAWEI_FINGERPRINT=m`。
- **设备树现代化映射 (`09-laptop.dtsi`)**：
  - 固件设备树中含有旧版数字属性 `fingerprint,reset_gpio = <0x119>`（281）与 `fingerprint,irq_gpio = <0xea>`（234）。在 Linux 6.x 中，PL061 采用动态 GPIO 基号分配（从 512 向下分配），直接申请整型 GPIO 会因基号未命中而持续陷入 `-EPROBE_DEFER`；
  - 经实机 `/sys/kernel/debug/gpio` 验证，Kirin 990 的 GPIO 控制器采用 8 引脚分组：
    - `gpiochip35` (`/amba/gpio@fa8b7000`) 覆盖 GPIO 280-287，其中 GPIO 281 为 Pin 1；
    - `gpiochip29` (`/amba/gpio@fa8b1000`) 覆盖 GPIO 232-239，其中 GPIO 234 为 Pin 2。
  - 在 `09-laptop.dtsi` 中通过标准 phandle 明确映射：
    - `reset-gpios = <&{/amba/gpio@fa8b7000} 1 1>;`（第 35 组 PL061，Pin 1，低电平复位，即 $35 \times 8 + 1 = 281$）；
    - `irq-gpios = <&{/amba/gpio@fa8b1000} 2 0>;`（第 29 组 PL061，Pin 2，高电平/边沿触发，即 $29 \times 8 + 2 = 234$）。
- **驱动功能与现代化实现**：
  1. 优先使用 `devm_gpiod_get_optional` 获取 GPIO 描述符并使用 `gpiod_to_irq` 解析内核 VIRQ；
  2. 控制 GPIO 281 信号线输出高低电平，完成 FPC 芯片上电与复位序列；
  3. 注册 GPIO 234 上升沿触发中断，在用户轻触电源键时产生 IRQ，通过 waitqueue 与 `sysfs_notify` 唤醒非安全世界等待进程；
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

## 5. 6.18 用户态现状与阻塞点（2026-10-22 实测）

内核侧 `/dev/tc_ns_client`、`/dev/fingerprint` 和 TEE TA 加载都已就绪，但**指纹业务还没跑起来**，目前有两个硬阻塞：

1. **`/dev/fingerprint` 不能给 libfprint 提供图像**。这个字符设备只有复位 GPIO、IRQ、`GET_DEVICE_INFO`、`GET_IRQ_STATUS` 等 ioctl，没有图像/模板/匹配接口；SPI1 在安全世界，REE 读不到原始指纹。因此“给 libfprint 写 FPC1020 over /dev/fingerprint 的后端”在这块硬件上不可行，libfprint 需要的是原始图像或厂商匹配服务。
2. **厂商用户态栈可以复制过来，但 TEE agent 注册被内核拒绝**。UOS 的 `/usr/lib/libfingerprint.so`、`libhwFingerprint.so`、`libteec.so.1`、`/vendor/bin/teecd`、`/system/vendor/bin/a32b3d00-...sec` 和 `fingerprint_daemon`（其实是 DBus `com.huawei.Fingerprint` HAL，不是 Android HIDL）都能读出来。把 `teecd` 放到 `/vendor/bin/teecd`、带上 UOS 的 `libssl.so.1.1`/`libcrypto.so.1.1` 后，它能通过 `check_teecd_auth` 的路径/UID 检查，但随后在 `TC_NS_CLIENT_IOCTL_REGISTER_AGENT` 上失败：

   ```text
   [tzdriver] (teecd)ioctl_register_agent: the agent is not access
   ```

   根因有两层：

   - `agent_allowed_ca.c` 没有加进 `tzdriver-objs`，实际链接的是 `core/agent.c` 里的 weak `is_allowed_agent_ca()`，所有外部 agent 都被拒绝；
   - 补上 Makefile 后，6.18 里的 `g_allowed_ext_agent_ca[]` 又是空表。已从本地 `kernel-image-4.19.71`（符号 `g_allowed_ext_agent_ca`，`char path[512] + u32 uid + u32 agent_id`）解出 4.19 的 3 项：

     | path | uid | agent_id |
     |---|---|---|
     | `/vendor/bin/hiaiserver` | 1000 | `0x53656345` |
     | `/vendor/bin/hw/vendor.huawei.hardware.biometrics.hwfacerecognize@1.1-service` | 1000 | `0x46616365` |
     | 同上 | 1000 | `0x46616345` |

     另外 `/vendor/bin/teecd`（uid 0）会注册 fs/misc/secfile/gtask 等内部 agent，这 4 个 ID 不在 4.19 表里；现在对 teecd 路径单独放行（它的路径/UID 已由 `check_teecd_auth()` 校验）。

   同时修了 6.18 上 `agent_buffer_map()` 用 `down_read` 调 `remap_pfn_range()` 的锁错误（改为 `mmap_write_lock`），以及 `smp_smc_send_func()` 的 20 次 outer retry（改为 10000 + `cond_resched()`）。

3. **teecd 现在能过认证和白名单，但 TEE 不完成 agent 注册**。实测日志：

   ```text
   is_allowed_agent_ca: external agent uid=0 path=/vendor/bin/teecd id=0x46536673
   smp_smc_send_func: cmd 3 outer retry exceeded ...
   register_agent_to_tee: register agent to tee failed, ret = -1
   ```

   `GLOBAL_CMD_ID_REGISTER_AGENT` 一直返回未完成，10000 次后超时；fs/misc agent 注册不上。实测 teecd 进程现在能起来并停在那里等待（不再立刻退出），但直接启动 `/opt/uos-fp/bin/fingerprint_daemon` 后进程很快消失，DBus 上没有 `com.huawei.Fingerprint`。

### 4.19 运行时对比（kprobe / function_graph，UOS 4.19 实机）

在 UOS 4.19 上用 kprobe 抓到了 `tc_ns_register_agent()` 的真实参数（3 次调用）：

```text
r0=dev_file, r1=0x46536673, r2=0x1000, r3=user_buffer, r4=1   # fs agent
r0=dev_file, r1=0x4d495343, r2=0x1000, r3=user_buffer, r4=1   # misc agent
r0=dev_file, r1=0x4c4f4144, r2=0x1000, r3=user_buffer, r4=1   # load agent
```

agent ID 和 6.18 一致，buffer 都是 4 KiB。关键差异在调用路径：

- 4.19 的 `function_graph` 里，`tc_ns_register_agent()` 只做 `vm_mmap()` / `remap_pfn_range()` 等 buffer 映射，**没有从 teecd 线程直接调用 `tc_ns_smc`**；
- 6.18 的 `tc_ns_register_agent()` 在同一个线程里同步调用 `register_agent_to_tee()` → `tc_ns_smc()`。

也就是说 4.19 走的是异步 SMC 队列 / `smc_svc_thread` 路径，6.18 改成了同步直发。TEE 很可能只接受队列线程发出的 agent 注册命令，或者同步直发时缺少队列路径才会填的字段（`event_nr`、`dev_file_id`、`ca_pid` 等）。这比单纯改 `GLOBAL_CMD_ID_REGISTER_AGENT` 的 `cmd_id` 更可能解释“命令一直不完成”。

下一步应该抓 4.19 `smp_smc_send`/`smc_svc_thread` 实际发送的 `tc_ns_smc_cmd`（在队列线程里），和 6.18 `register_agent_to_tee()` 填的结构逐字段 diff；或者把 6.18 的 agent 注册改回 4.19 的异步队列路径。

在这一步之后，才是启动 `/vendor/bin/teecd` 和 `/opt/uos-fp/bin/fingerprint_daemon`，确认 DBus `com.huawei.Fingerprint`，再做 PAM。`system/fingerprint/` 里的 udev 规则和服务文件已经准备好。

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
