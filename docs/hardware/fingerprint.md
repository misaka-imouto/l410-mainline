# 电源键指纹识别与 TrustZone 安全子系统

华为擎云 L410 笔记本配备了与电源键集成的电容式指纹传感器（Power-button Fingerprint Sensor）。
在架构设计上，为了满足高安全级别的生物特征保护规范，麒麟 990 平台采用了 ARM TrustZone 硬件安全隔离方案，指纹采集与特征比对完全在安全世界（Secure World）内闭环完成。

在 Linux 6.18 主线内核中，我们通过引入 **iTrustee tzdriver** 安全客户端网关驱动与 **huawei-fingerprint** 平台驱动，完整打通了从内核设备节点、TrustZone 通信通道到用户态守护进程与桌面 PAM 生物认证的完整技术栈。

> **当前状态（2026-10-24）**：整条栈已实机跑通——录入、识别、模板落盘、KDE 设置、
> `fprintd` D-Bus 替身、`sudo` 指纹、KDE 锁屏解锁都验证过。待办：
> ① 删除已录入模板（`l410-fp-del` 待实机确认 ABI）；② SDDM 登录界面指纹；
> ③ **一次真实触摸的回归**（等待/中断语义已按 UOS 对齐，见 §6.23，但没有手指在机器旁
> 时只能验证到“HAL 正常阻塞在 poll()”）。
> 下文 §5~§6.19 是调试过程记录，里面的“阻塞/未做”只代表当时；
> 当前结论看 §6.20、§6.23 和 [known-issues.md](../known-issues.md)。

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
|  [ pam_fprintd ] <-> [ l410-fprintd-shim: net.reactivated.Fprint ]    |
|               |               (代理到 com.huawei.Fingerprint)             |
|               +----------------+                                       |
|                                |                                       |
|     [ fingerprint_daemon ] <---+ (DBus: com.huawei.Fingerprint)        |
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
3. **`l410-fprintd-shim` / Linux PAM**：
   - 替身持有 `net.reactivated.Fprint`，把 `pam_fprintd` / KDE 设置 / `fprintd-*` 的请求代理到厂商的 `com.huawei.Fingerprint`。
   - `sudo` 用 `/etc/pam.d/sudo` 的 `pam_fprintd`；KDE 锁屏用 plasma 自带的 `/usr/lib/pam.d/kde-fingerprint`。
   - `deepin-authenticate` 不是必需的，装不装都不影响这条链路。

---

## 5. 6.18 用户态现状与阻塞点（2026-10-22 实测，历史）

> 本节记录的是 2026-10-22 的状态；两个“硬阻塞”后来都已解决（见 §6）。
> 现在请直接读 §6.20 和文首的当前状态。

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

进一步用 function_graph + kprobe 确认：4.19 的用户态 agent 注册**根本不需要发 `GLOBAL_CMD_ID_REGISTER_AGENT`**，TEE 侧已经由 TA 声明；6.18 的同步直发是多余且会让 Kirin 990 TEE 一直不置完成位。把 6.18 的 `tc_ns_register_agent()` 改成对 `user_agent == true` 跳过 `register_agent_to_tee()` 后，`teecd` 立即能起来：

```text
send_event_response: agent 0x4c4f4144 ... sends answer back
send_event_response: agent 0x4d495343 ... sends answer back
send_event_response: agent 0x46536673 ... sends answer back
```

### 下一个阻塞：4.19 用户态 ABI 与 6.18 内核不一致

`teecd` 能起来之后，直接启动 UOS 的 `fingerprint_daemon` 失败：

```text
fingerprint_dae: tc_client_agent_ioctl: invalid cmd 0x40b07401!
```

`0x40b07401` 是 4.19 的 `TC_NS_CLIENT_IOCTL_SES_OPEN_REQ`，编码里的结构大小是 `0xb0`。6.18 的 `struct tc_ns_client_context` 只有 `0xa0`，所以 `_IOW('t', 1, struct tc_ns_client_context)` 算出来的 ioctl 号不同，`tc_client_ioctl()` 的 switch 不认，落到 agent ioctl 分支。`teecd` 的 `GET_TEE_VERSION`（`0xc0047415`）也遇到同类问题。

因此要让 UOS 的 `libteec`/`fingerprint_daemon` 直接跑，需要在 6.18 内核里加 4.19 的 ioctl ABI 兼容层（接受 `0xb0` 的 context 并转换到 6.18 结构），或者重新编译一个 6.18 原生 `libteec`/HAL。下一步优先做前者：只兼容 `SES_OPEN`/`SES_CLOSE`/`SEND_CMD`/`GET_TEE_VERSION`/`WAIT_EVENT` 这几个 HAL 实际用到的命令。

在这一步之后，才是启动 `/vendor/bin/teecd` 和 `/opt/uos-fp/bin/fingerprint_daemon`，确认 DBus `com.huawei.Fingerprint`，再做 PAM。`system/fingerprint/` 里的 udev 规则和服务文件已经准备好。


> **2026-10-22 下午更新**：上面这个 ABI 兼容层已经写完并实测通过（linux-l410 提交
> `cf0f1476d`），`0x40b07401` 不再是问题；现在的阻塞变成 TEE 侧不完成用户态发起的
> 全局 SMC（`NEED_LOAD_APP`）。详见第 6 节。

## 6. 4.19 用户态 ABI 兼容层（2026-10-22 下午，已完成）

### 6.1 结论先行

`drivers/tee/itrustee` 里的 `tc_client_419_session_ioctl()` / `tc_ns_load_secfile_419()`
（linux-l410 提交 `cf0f1476d`）已经让 UOS 的 `fingerprint_daemon` 通过了 ABI 这一关：

```text
之前： [tzdriver] (pid, fingerprint_dae)tc_client_agent_ioctl: invalid cmd 0x40b07401!
现在： cat /proc/<daemon>/stack
       smp_smc_send_func+0x8bc/0xf24 [tzdriver]
       proc_tc_ns_smc+0x64/0x134 [tzdriver]
       tc_ns_smc_skip_kill+0x18/0x24 [tzdriver]
       tc_ns_need_load_image.constprop.32+0xe0/0x1e0 [tzdriver]
       tc_ns_open_session+0x1dc/0xb48 [tzdriver]
       tc_client_419_session_ioctl+0x27c/0x438 [tzdriver]
       tc_client_ioctl+0x108/0x580 [tzdriver]
       __arm64_sys_ioctl+0xa8/0xd0
```

即 ioctl 号、结构体转换、TA 镜像大小/地址都已正确送进 `tc_ns_open_session()`。
**现在卡住的不是 ABI，而是 TEE 侧不完成 SMC 命令**，见 6.4。

### 6.2 4.19 ABI 实测结果（4.19 内核反汇编 + 实机 kprobe）

`struct tc_ns_client_context`：4.19 是 **0xb0**，6.18 是 **0xa0**，公共前缀逐字节相同。

| 偏移 | 4.19 | 6.18 |
|---|---|---|
| 0x00 | `uuid[16]` | 同 |
| 0x10 / 0x14 | `session_id` / `cmd_id` | 同 |
| 0x18 / 0x20 | `returns` / `login` | 同 |
| 0x28…0x88 | `params[4]`，步长 0x18 | 同 |
| 0x88 / 0x8c | `param_types` / `started` | 同 |
| 0x90 | libteec 私有 8 字节指针 | `calling_pid` |
| 0x98 | libteec 私有 u32（值为 24） | `file_buffer` 低半部 |
| 0xa0 | `file_size` | — |
| 0xa8 | `file_buffer` | — |
| 0x94 / 0x98 | — | `file_size` / `file_buffer` |

0x90/0x98 在 4.19 内核里**从不被读**（只随整个 0xb0 copy_to_user 回用户态），
所以兼容层原样保留这 16 字节，只搬运 `file_size`/`file_buffer`。

ioctl 号（`_IOW/_IOWR('t', nr, sizeof(struct))`）：4.19 与 6.18 只在“参数结构体尺寸变了”的命令上不同。

| 命令 | 4.19 | 6.18 |
|---|---|---|
| SES_OPEN_REQ | `0x40b07401` | `0x40a07401` |
| SES_CLOSE_REQ | `0xc0b07402` | `0xc0a07402` |
| SEND_CMD_REQ | `0xc0b07403` | `0xc0a07403` |
| CANCEL_CMD_REQ | `0xc0b0740d` | `0xc0a0740d` |
| LOAD_APP_REQ | `0xc0207409`（32 字节参数） | `0xc0247409`（36 字节 packed） |
| REGISTER_AGENT | `0xc0107407`（16 字节） | 同 |
| WAIT_EVENT / SEND_EVENT_RESPONSE / UNREGISTER_AGENT / LOGIN | `0xc0047405` / `06` / `08` / `0e` | 同 |
| GET_TEE_VERSION | `0xc0047415` | 同 |

4.19 的 secfile 参数是 `{u32 type; u8 uuid[16]; u32 file_size; char *file_buffer;}`
（32 字节）；6.18 是 `struct sec_file_info + uuid + union`（packed，36 字节）。

实机 kprobe（UOS 4.19 跑 `fingerprint_daemon`，`tc_ns_open_session` 入口）：

```text
uuid    = a32b3d00-cb57-11e3-9c1a-0800200c9a66   （指纹 TA）
cmd_id  = 2      login.method = 7      param_types = 0x1
+0x90   = 用户态指针        +0x98 = 0x18
+0xa0   = 0x14c7c0 (=1361856，正好是 .sec 文件大小)
+0xa8   = TA 镜像用户态地址
```

### 6.3 顺带查清的两件事

1. **CA 用的 `/dev/tc_ns_client` fd 是 teecd 给的。** 4.19 上 `fingerprint_daemon` 打开
   设备后，dev_file 里的 `pub_key` 已经是 `"/usr/bin/fingerprint_daemon"`（27 字节，
   即 CA 自己的 exe 路径）、`pkg_name` 是 4 字节 uid —— 而 daemon 自己并没有发过
   `LOGIN`。是 teecd 通过 socket 收到请求后，用 `SO_PEERCRED` 拿到 CA 的 pid/路径，
   替它做 `LOGIN`，再把准备好的 fd 传过去。因此 6.18 里“只有 teecd 能打开
   `/dev/tc_ns_client`”这条门禁必须放宽到只保护 `/dev/tc_private`。

2. **LOGIN 证书的两个字段顺序，4.19 和 6.18 是“双重互换”，净效果一致。**
   4.19 是 `[pub_key_len][pub_key][pkg_name_len][pkg_name]`，
   6.18 解析成 `[pkg_name_len][pkg_name][pub_key_len][pub_key]`；
   而 open session 时 4.19 把 pub_key 放 `params[3]`/pkg_name 放 `params[2]`，
   6.18 正好相反。所以同一条 UOS 证书在两个内核上送到 TEE 的内容相同，不用改。

3. `GET_TEE_VERSION` 在兼容层里**故意不在 client 节点上放行**：两边 ioctl 号相同
   （`0xc0047415`），但 6.18 发这个 SMC 会让 `smp_smc_send_func` 卡到重试上限，
   teecd 启动时直接卡死；而 vendor teecd 对 `-EINVAL` 是能容忍的（下一节会看到）。

### 6.4 当前阻塞：TEE 不完成“用户态发起”的全局 SMC 命令

在 6.18 上按顺序起 `teecd` + `fingerprint_daemon`（脚本见
[system/fingerprint/run-uos-stack.sh](../../system/fingerprint/run-uos-stack.sh)）：

```text
[tzdriver] (6654, teecd)tc_client_agent_ioctl: invalid cmd 0xc0047415!   # GET_TEE_VERSION，预期
[tzdriver] (6656, teecd)tc_client_agent_ioctl: invalid cmd 0xc0087411!   # SYNC_SYS_TIME，预期
[tzdriver] (kworker)show_timeout_cmd_info: pid=6695,pname=fingerprint_dae,
           lastcmdid=5 ... timedif=10525 ms
```

`cmd 5 = GLOBAL_CMD_ID_NEED_LOAD_APP`，是 `tc_ns_open_session()` 加载 TA 前的第一步。
`fingerprint_daemon` 的栈停在 `smp_smc_send_func()`（见 6.1），TEE 始终不置完成位。

对照实验（都是同一台机器、同一次启动）：

| 命令 | 谁发起 | 6.18 结果 |
|---|---|---|
| `REGISTER_MAILBOX` (0x17)、`REGISTER_NOTIFY_MEMORY` (0x8)、`REGISTER_RESMEM` (0x24) | 内核 modprobe 阶段 | ✅ 正常完成 |
| `NEED_LOAD_APP` (0x5) | 用户态 CA（daemon） | ❌ 永不完成 |
| `GET_TEE_VERSION` (0x22) | 用户态（teecd） | ❌ 永不完成 |
| `REGISTER_AGENT` (0x6) | 用户态（teecd） | ❌ 永不完成（与上一轮交接文档一致） |

也就是说：**内核自己发的全局命令能通，用户态 dev_file 发起的全局命令不通**；agent
事件（`WAIT_EVENT`/`SEND_EVENT_RESPONSE`）不受影响。

已经排除/验证过的：

- 不是 ioctl ABI（6.1 的栈已经进到 `tc_ns_open_session`）；
- 不是结构体尾部（0x90/0x98 保留、`file_size`/`file_buffer` 映射都正确）；
- 不是 `nsid`/`vmid`：清零后 `NEED_LOAD_APP` 依旧不完成（实验已回滚，代码未入库）；
- 不是 `paramtypes`：4.19 的同一命令用 `TEEC_MEMREF_TEMP_INOUT` / `TEEC_VALUE_OUTPUT`，
  与 6.18 完全一致（反汇编逐条比对过）；
- 不是 mailbox 池：4.19 和 6.18 都是 4 KiB 参数页 + `mb_cmd_pack`；
- 不是 `tc_ns_smc_cmd` 本身：见 6.5 的逐字段对比，把 `cmd_type`/`nsid`/`vmid`
  全对齐到 4.19 的取值后仍然卡住。

### 6.5 对照实验：`tc_ns_smc_cmd` 字段逐项对比（4.19 vs 6.18）

用 kprobe（4.19）和临时 hexdump（6.18，`proc_tc_ns_smc()`）抓同一条
`NEED_LOAD_APP` 交给 `tc_ns_smc()` 的结构体，字段级对比结果：

| 字段 | 4.19（真机） | 6.18（原样） | 6.18（对齐后） |
|---|---|---|---|
| `cmd_type` | **1** | 0（`CMD_TYPE_GLOBAL`） | 1 |
| `cmd_id` | 5 | 5 | 5 |
| `dev_file_id` | 8 | 6/8（取决于开 fd 顺序） | 同 |
| `context_id` / `agent_id` | 0 / 0 | 0 / 0 | 0 / 0 |
| `operation_phys` / `_h_phys` | 0x1200b000 / 0x8 | 0x14403000 / 0x1 | 同 |
| `login_*`、`err_origin`、`event_nr` | 全 0 | 全 0 | 全 0 |
| `uid` / `ca_pid` / `pid` | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| `nsid` | 0（该偏移已在其结构体之外） | **0xEFFFFFFC**（`PROC_PID_INIT_INO`） | 0 |
| `vmid` / `eventindex` / `started` | 0 | 0 | 0 |

把 6.18 的 `cmd_type` 改成 1、`nsid`/`vmid` 清零之后，结构体**已经和 4.19 完全一致**，
但 `NEED_LOAD_APP` 依旧永不完成。结论：**问题不在 `tc_ns_smc_cmd`，而在
`smp_smc_send()` 把它送进共享内存队列的那一层**（队列条目布局 / `in_bitmap`
槽位分配 / `event_nr` 复用 / SMC 寄存器参数）。两个已知的 ABI 级差异先记在这里：

- 4.19 的 `struct tc_ns_smc_cmd` 里 `cmd_type` 是 **u8**（`cmd_id` 在 +17），
  6.18 是 **u32**（`cmd_id` 在 +20），尾部 6.18 还多了
  `nsid`/`vmid`/`eventindex`/`res_int[3]`/`started`。**如果队列条目是直接 memcpy**
  结构体，字段就会整体错位 —— 这值得优先验证（对比 4.19 和 6.18
  `smp_smc_send()` 里往 `g_cmd_data->in[]` 写字段的偏移）。
- 4.19 全局命令的 `cmd_type` 是 **1**，6.18 的 `CMD_TYPE_GLOBAL` 是 **0**。

下一步建议（按性价比排序）：

1. 在 `smp_smc_send()` 里打印/对比真正写进共享内存的那个队列条目（不是
   `tc_ns_smc_cmd`）。4.19 的 `struct tc_ns_smc_queue` 布局可以从
   `kernel-image-4.19.71` 反汇编 `smp_smc_send`（`ffffff8008dfa530`）确认。
2. 对齐 `cmd_type`（Kirin 990 上全局命令发 1）——单独改没有解决问题，但和上面那条一起
   才是 4.19 的真实线上字节。
3. 检查 `init_for_smc_send()` 的槽位分配与 `event_nr`（6.18 把 `event_nr` 当命令索引
   复用），以及 `out_bitmap`/`in_bitmap` 的位序是否和 TEEOS 一致。
4. 用 `GLOBAL_CMD_ID_DUMP_SRV_SESS` (0x25) 之类已有调试入口，确认 TEE 侧到底有没有
   收到这条命令（如果 TEE 收到但不回，方向是握手/权限；如果 TEE 根本没收到，就是队列）。

在这之后才是：确认 DBus `com.huawei.Fingerprint`、把 `deepin-authenticate`/PAM 接上。

### 6.6 队列条目布局：`cmd_type` 必须是 u8（linux-l410 `798e8f783`）

4.19 内核交给 `tc_ns_smc()` 的结构体在 `+16` 处是一个**单字节** `cmd_type`，
所以 `cmd_id` 在 `+17`、`dev_file_id` 在 `+21`；6.18 原来是 u32，`cmd_id` 在 `+20`，
整个前缀在共享队列里错位 3 字节。改成 u8 后：

- 空闲的 `SET_SERVE_CMD` 不再空转到 10001 次重试上限（原来每次约 37 秒），
  现在立刻完成并被重新发起；
- `fingerprint_daemon` 不再永久卡在第一条 SMC 上，会像 vendor 栈那样重试 TA 加载。

对齐后的行为（6.18，`g_cmd_data->in[]` 里的字节已经和 4.19 一致）：

```text
cmd_type = 1（Kirin 990 上 CMD_TYPE_GLOBAL 要发 1，其枚举里 TA 在前）
cmd_id   = 5 (NEED_LOAD_APP)   dev_file_id = 6
nsid     = 0                   vmid = 0
```

但 `NEED_LOAD_APP` 仍然不被 TEEOS 完成（`out_bitmap` 对应位始终不置），
所以 open session 还差这一步。下一个怀疑点已经很具体：

- `struct tc_ns_smc_queue` 的布局是 `in_bitmap / doing_bitmap / out_bitmap /
  in[18] / out[18]`，`out[]` 的偏移由 `sizeof(struct tc_ns_smc_cmd)` 决定。
  4.19 的结构体看起来是 **104** 字节（`pid` 结束于 81，后面还有保留字段），
  6.18 改成 u8 之后是 **109** 字节 —— `out[]` 起点会差 5×18=90 字节，
  TEE 写结果的位置和我们读的位置可能对不上。
- 验证方法：从 4.19 的 `smp_smc_send` / `occupy` 路径反汇编出
  `sizeof(tc_ns_smc_cmd)` 和 `out[]` 的偏移，然后把 6.18 的结构体尾部
  （`nsid`/`vmid`/`eventindex`/`res_int[3]`/`started`/`res_chr[3]`）裁到同样大小。
- 另一条线索：`NEED_LOAD_APP` 之后 TEE 可能要通过 LOAD agent 走事件通道
  （`agent call count: 0` 说明没有 agent 事件在等待，所以先确认 TEE 是否真的
  收到了这条命令）。

### 6.7 队列条目真尺寸：102 字节，尾部是 AUTH_ENHANCE 字段（linux-l410 `52ea66282`、`3ee085bab`）

6.6 怀疑的“104 字节”不对，反汇编 `kernel-image-4.19.71` 得到的是 **102 字节**，
并且尾部字段和 6.18 完全不同：

```text
ffffff8008dfaa0c  occupy: memcpy_s(dest = g_cmd_data + 0x20 + 0x66*idx, 0x66,
                                 src = stack, 0x66)          ; 条目 = 0x66 = 102
ffffff8008dfab60  copy_out: src = g_cmd_data + 0x750 + 0x66*idx ; out[] 基点 = 0x750
ffffff8008df9410  set_abort 清 in-entry +45/+49/+77/+81/+89..96 ; 见下
```

即队列头是 3 个 bitmap（各 8 字节）+ `smc_lock`(4) + `last_in`(4) = `0x20`，
`in[18]` 之后 `last_out` 4 字节，`out[]` 落在 `0x20 + 18*102 + 4 = 0x750`。
所以 6.18 原来的 109 字节条目让 `in[1..17]`/`out[0..17]` 全部错位，TEE 的结果
写在驱动读不到的地方。

4.19 真机（`CONFIG_AUTH_ENHANCE=y`）尾部和 6.18 的对应关系如下（用 openEuler
iTrustee 仓库 `368a6eb` 的同一段源码交叉验证；它的 `set_abort_cmd()` 恰好只清
`token_phys/token_h_phys/params_phys/params_h_phys`，地址和 4.19 反汇编逐字对上）：

| 偏移 | 4.19（102 字节） | 6.18（109 字节） |
|---|---|---|
| 0..15 | `uuid` | `uuid` |
| 16 | `u8 cmd_type` | `u8 cmd_type` |
| 17..76 | `cmd_id` … `ca_pid` | 同（逐字节一致） |
| 77 | `token_phys` | `pid`（tgid） |
| 81 | `token_h_phys` | `nsid` |
| 85 | `pid`（tgid） | `vmid` |
| 89 | `params_phys` | `eventindex` |
| 93 | `params_h_phys` | `res_int[0]` |
| 97 | `eventindex` | `res_int[1]` |
| 101 | `bool started` | `res_int[2]`（+`started`@105、`res_chr[3]`@106） |

16+1+21*4+1 = 102。注意：4.19 没有 `nsid`/`vmid`/`res_int`/`res_chr`；旧 TEEOS
不认识它们。**更要紧的是**，6.18 把 tgid 放在 77，旧 TEEOS 会把 tgid 当
`token_phys` 用（一个随机的“物理地址”）。

实现（`core/smc_smp.h`、`core/smc_smp.c`）：

- 新增 `struct tc_ns_smc_cmd_wire`（上面的 102 字节布局，`compile_time_assert`）；
- `struct tc_ns_smc_queue` 的 `in[]`/`out[]` 改用 wire 结构；
- `occupy_free_smc_in_entry()` / `copy_smc_out_entry()` 两个边界上做
  `smc_cmd_to_wire()` / `smc_cmd_from_wire()` 转换，丢弃 `nsid`/`vmid`，
  `token/params` 留 0（vendor 对全局命令也是 0），tgid 搬到 85；
- `set_abort_cmd()` 补上 vendor 会清的 `token_phys/token_h_phys/params_phys/params_h_phys`。

实测 md5 与本地构建一致，加载后 `mailbox_register` 终于读到 TEEOS 的**真实**回复：

```text
[tzdriver] mailbox_register: resigter mailbox failed, ret=-65530
```

`-65530 == 0xFFFF0006 == TEE_ERROR_BAD_PARAMETERS`。也就是说这条
`GLOBAL_CMD_ID_REGISTER_MAILBOX` 一直被 TEEOS 拒绝，只是旧代码读的是
（永远为 0 的）错位 `out[]`，误以为成功，模块才得以加载。原因是 4.19 的
注册协议不同：vendor 注册**一整块连续** `MAILBOX_POOL_SIZE`，两个参数都是
`VALUE_INPUT`，传的是 `page_address(all_pages)`；6.18 传的是
`mailbox_buffer[]` 数组。在 legacy Kirin 990 上照 vendor 协议注册 pool 0 现在
**成功**（`-- mailbox_register: wish to register 8 mailbox, success 8`，
`mailbox_init: legacy mailbox register ret=0`，见 `8979446bf`）。注意：不注册
mailbox 时，TEEOS 会在 `load_image_by_frame` 里 `gtask` 的 `memcpy` 中缺页。

### 6.8 TA 镜像已能加载；open session 卡在 AUTH_ENHANCE（`8979446bf`）

修完 queue 之后，TEEOS 才真正开始处理用户态命令，接连暴露出两个 legacy
不兼容点：

1. **mailbox 注册**（6.7）：按 vendor 协议注册 `MAILBOX_POOL_SIZE` 连续池，
   两个参数都用 `VALUE_INPUT`。
2. **TA 加载 paramtypes**：4.19 的 `LOAD_SECURE_APP` operation 用的是
   **`0x1627`**（`load_image_by_frame` 反汇编 @ `ffffff8008dfde94`：
   `MEMREF_TEMP_INOUT, VALUE_OUTPUT, MEMREF_TEMP_OUTPUT, VALUE_INPUT`），
   既不是 6.18 的 `0x3605` 也不是 openEuler 源码的 `0x1635`。

实测（6.18 + UOS 用户态）：`/vendor/bin/teecd` + `fingerprint_daemon` 起来后，
1.3 MiB 的指纹 TA 分两帧全部 `ret=0` 加载成功，接着发 `GLOBAL_CMD_ID_OPEN_SESSION`
（cmd 2）。但它返回：

```text
post_proc_smc_return: smc call ret 0xffff0000, cmd ret val 0xffff0000, origin 3
proc_open_session: smc call returns error, ret=0xe
tc_client_419_session_ioctl: 4.19 open session failed ret is 14
```

`0xffff0000 == TEE_ERROR_GENERIC`。反汇编 4.19 的 `load_security_enhance_info`
（`ffffff8008df5ac4..8df5bc4`）可见：当 `cmd_id == GLOBAL_CMD_ID_OPEN_SESSION`
时，4.19 会设置 `token_phys@77`/`token_h_phys@81`（来自 4.19 CA token）和
`params_phys@89`/`params_h_phys@93`（加密后的 session secure params），而我们的
wire 结构这两处仍发 0。所以下一个要移植的是 `CONFIG_AUTH_ENHANCE`：

- 用户态 `libteec`/`teecd` 已经把 token 放在 4.19 context 的私有区里
  （`append_teec_token`，`ffffff8008df6030`），需要在 4.19 ABI 转换时把它
  映射到 wire 的 `token_phys/token_h_phys`；
- `params_phys/params_h_phys` 来自内核 `generate_encrypted_session_secure_params()`
  （openEuler 源码 `auth/security_auth_enhance.c`），需要实现同一套 session
  密钥/加密流程，否则 TEEOS 不肯开 session。

在 `8979446bf` 之前的所有观察都建立在“错位 out[] 永远返回 0”的假象上；
现在队列、mailbox、TA 加载三块已是真实通过，后续调试请以 TEEOS 真实返回值
为准。

### 6.9 AUTH_ENHANCE：root key 与 session key 已打通（`7cc2d349e`）

用 kprobe 在 UOS 4.19 上抓 `tc_ns_smc`，得到 vendor 对三种命令实际填的字段：

| cmd | 类型 | operation | login | token | params |
|---|---|---|---|---|---|
| `0x16` GET_SESSION_SECURE_PARAMS | global | 0 | 0 | 0 | ✅ |
| `0x02` OPEN_SESSION | global | ✅ | ✅ | ✅(42B) | ✅(80B+IV) |
| TA invoke（`0x37/0x3b/0x3c` 等） | TA | ✅ | 0 | ✅ | 0 |

**root key 的来源**：不是单独 SMC，而是 `smc_context_init()` 把命令缓冲区
物理地址交给 TEEOS（SMC `0xb2000008`）后，TEEOS 把 48 字节（AES-256 key 32 +
IV 16）写在 `g_cmd_data->in[0] + 4`，即 legacy magic `0` 之后。4.19 的
`get_session_root_key()`（`ffffff8008df6d50`）就是从 `cmd_data + 0x24` 拷 48
字节再把 `in[]` 清零。实测 6.18 启动时该处确实是 `0, <32 字节随机>, 0,0,0`，
和 4.19 完全一致。`parse_params_from_tee()` 现在在 memset 之前把它存下来。

**session key 交换**：`core/auth_enhance.c` 实现

1. `GLOBAL_CMD_ID_GET_SESSION_SECURE_PARAMS`（0x16）：随机 challenge word，
   放进 `session_secure_params`，用 `params_phys` 发给 TEEOS；TEEOS 返回用
   root key 加密的 blob，AES-256-CBC 解密（IV 在密文尾部 16 字节），得到
   `scrambling[3]` 和 `crypto_info`（session key + IV）。
2. 开 session 时：`token_phys` 指向 42 字节全 0，`params_phys` 指向“challenge
   用 session key 加密”的 96 字节 blob。

注意：`CONFIG_PAGES_MEM` 的 mailbox 是 `ioremap_cache` 的，`skcipher` 在它上面
`flush_dcache_page()` 会拿到无效 `struct page` 直接 oops；所以加解密都要先拷到
普通 `kmalloc` 缓冲再交给 skcipher。

实测：root key 已装入，0x16 成功且回包能解密，open session 的
`op/token/params` 已和 vendor 一致（6.18：`op=0x14403000 tok=0x144030b8
params=0x144030e2`；UOS：`op=0x1200b000 login=0x1200b078 tok=0x1200b0e8
params=0x1200b112`）。但 TEEOS 仍回 `TEE_ERROR_GENERIC`，差别是
**`login_data_phy=0`**。

**下一步（CA 认证）**：vendor 的 `need_check_login()` 要求
`pub_key_len == sizeof(uint32_t)`，并由 `check_login_for_encrypt()` 把
`sess->auth_hash_buf` 用 session key 做 `do_encryption()`（带 encryption head
和 CMS padding）后放 `login_data`，长度 64。4.19 teecd 通过 CA 身份/证书
ioctl 设置 `pub_key_len`（我们的 4.19 ABI 层还没转这个 ioctl），且 6.18 的
`auth_hash_buf` 布局（64 字节裸 hash）和 vendor（112 字节含 head/IV）不同。
所以还剩：\*\*4.19 CA 证书 ioctl 兼容 + auth_hash 的 AUTH_ENHANCE 加密格式\*\*。

### 6.10 CA 认证数据已和 UOS 逐字节对齐（`dc6eb92ff`）

用 kprobe 在 UOS 4.19 上抓 `do_encryption` 和 `tc_ns_smc`，把 CA 认证数据
一项项对齐后，6.18 侧已经和 vendor 完全一致：

1. **CA hash 之前一直是 0**：`calc_client_auth_hash()` 整体在
   `#ifdef CONFIG_CLIENT_AUTH` 里，而 Makefile 只定义了 `CONFIG_AUTH_HASH`。
   加上 `-DCONFIG_CLIENT_AUTH` 后，`auth_hash_buf[32..63]` 变成
   `24 37 ff 6c 70 87 34 30 ...`，和 UOS 抓到的 CA hash **逐字节相同**。
   同时要修两处 6.18 API：`get_user_pages_remote()` 在 6.5+ 少一个参数；
   `find_lib_code_area()` 的 `mm->mmap`/`vm_next` 在 6.1+ 要换成
   `VMA_ITERATOR`/`for_each_vma`。
2. **去掉 `CONFIG_AUTH_HASH` 和 `CONFIG_AUTH_SUPPORT_UNAME`**（UOS config
   里没有这两个）：否则 `set_login_information_hash()` 会把 `pkg_name`
   换成 32 字节 digest，`pub_key` 变成用户名。去掉后 `pkg_name` 是 CA 路径
   （`/usr/bin/fingerprint_daemon`，27 字节），`pub_key` 是 uid（4 字节），
   与 UOS 的 `do_encryption` 输入（payload 28 / 5）一致。
3. **login_data 加密**：`auth_enhance_encrypt_login_info()` 做
   `AES-CBC(head || 64 字节 hash || CMS padding) + IV`，输出 112 字节，
   `login_data_len` 保持 64。
4. **open session 的 params[2]/[3] 也要加密**：vendor 的
   `do_opensess_auth_enhance()` 会把 CA uid / CA 路径用 session key 加密，
   对应 `auth_enhance_encrypt_open_param()`。

结果：open session 的 `op/login/token/params` 四个 phys、`login_data_len`、
CA hash、params[2]=4B、params[3]=27B 全部和 UOS 一致，但 TEEOS 仍回
`TEE_ERROR_GENERIC`（origin COMMS）。

**下一个明确线索**：UOS 的命令流在 open 之前还有一条
**`GLOBAL_CMD_ID_SET_CA_HASH` (0x13)**，6.18 从未发过（命令序列里只有
`0x1b/0x17/0x5/0x4/0x2`）。它由 `SET_NATIVECA_IDENTITY` ioctl →
`tc_ns_set_native_hash()` 触发，而 6.18 只把该 ioctl 放在
`tc_private_ioctl`（teecd 的 `/dev/tc_private`）；4.19 teecd 是在 client 节点
（`/dev/tc_ns_client`）上发 `0xc0047415`/`0xc0087411` 等 ioctl 的，所以
`SET_NATIVECA_IDENTITY` 大概也在 client 节点上被 `tc_client_ioctl` 的
`default` 分支当成 invalid 丢掉了。下一步：在 client 节点上兼容 4.19 的
`SET_NATIVECA_IDENTITY`，把 CA hash 注册给 TEEOS，再试 open。

### 6.11 open session 已打通；invoke 还差 token 同步（`7c7dcebdb`）

用 kprobe 抓 UOS 的 `tc_client_ioctl` 发现 teecd 的真实顺序是
`7415(GET_TEE_VERSION) → 7412(SET_NATIVECA_IDENTITY) → 7411 → 740e(LOGIN)`，
而 6.18 一直跳过 7412。继续反汇编 teecd（`0x2f08 set_native_identity`）发现
它会先读 **`/vendor/etc/native_packages.xml`**，读成功才 `ioctl(0xc0047412)`。
6.18 根上缺这个 2752 字节的二进制 native CA 数据库，所以 teecd 直接返回。
从 UOS 的 `/dev/sdd5` 只读拷过去后：

```bash
sudo mount -o ro /dev/sdd5 /mnt/uosro
sudo mkdir -p /vendor/etc
sudo cp /mnt/uosro/vendor/etc/native_packages.xml /vendor/etc/
```

再把 **`GET_TEE_VERSION` 和 `SET_NATIVECA_IDENTITY` 都加到 client 节点**
（`tc_client_ioctl`），teecd 就会发 `SET_CA_HASH`(0x13)。

**结果：open session 终于成功**（teecd → SET_CA_HASH → daemon open），
daemon 进入 invoke。接着 invoke 从 `TEEC_ERROR_INVALID_CMD(0x1)` 变成
`TEE_ERROR_GENERIC`，又补了三处 TA ABI：

1. vendor 枚举 `CMD_TYPE_TA=0 / CMD_TYPE_GLOBAL=1`，而我们是相反的；
   global 之前已映射，TA 也要 `1 → 0`；
2. TA 命令的 `operation_phys`/`pid` 要用 session 的 `scrambling[1]` 做 XOR
   （vendor `update_chksum()`），否则 TEE 在错的物理地址读 operation；
3. TA 命令要带 42 字节 AUTH_ENHANCE token：open 响应里的 token 存进
   `session->teec_token`，invoke 时把 libteec 的 16 字节 token（context
   0x90）合并进去、把 `token[32..39]` 的 scrambling timestamp 递增并标记
   unsynced。

现在 invoke 已被 TA 识别，但仍回 `TEE_ERROR_GENERIC`。剩下的是
**token/timestamp 同步的精确性**（`post_process_token`/`sync_timestamp`
的 DEC 逻辑、`token[40]` 的 kernel_api、以及 operation params 的逐字节
对齐）。

### 6.12 invoke token 结构已抓清；仍 GENERIC（待 operation buffer 对比）

在 UOS 上 kprobe `descrambling_timestamp`（`update_timestamp` 的底层），抓到真实
invoke token（42 字节）：

```text
token[0..31] = cfbdcb81 c190519c ec9d508f b4ecd9fa
               26e348f6 39bee508 fa5ebe16 848a26b7   (会话内固定)
token[32..39]= 5044f66f 50468e37 ...   (scrambled timestamp，逐次 ±1)
token[40]    = kernel_api
token[41]    = sync flag
scrambling[0]= 0x5044f66f   (timestamp 的 4 字节循环 XOR key)
```

把 timestamp 解扰后是一个**小整数计数器**（UOS 约 0x27858）。6.18 侧同样成立：
open 响应 token 的 timestamp 解扰 = **176051**（小计数器），说明 token 布局、
scrambling 偏移、timestamp 编码方向都是对的。

进一步验证：

- open 和 invoke 的 token 指针是**同一个合法用户态地址**（`0x...764`，len=24）；
- 实现 vendor `save_token_info()` 把 `[token 0..15 | timestamp 32..39]` 写回该
  地址，`copy_to_user` 返回 0（成功）；
- 但写回后下一条 invoke 会让 TEE 卡在 `doing_bitmap`（命令不返回），比原先
  「快速 GENERIC」更糟，已回滚到 `7c7dcebdb`。

当前 invoke 的 `cmd_id(0x29/0x66)、session_id(0xE0001)、token_phys、scrambled
operation_phys` 都与 UOS 的取值集合一致，但 TA 仍回 `TEE_ERROR_GENERIC`。
token/timestamp 已排除，下一个要对比的是 **operation buffer**
（`paramtypes` + `params[]`）的逐字节内容，以及 `token[40]`/`sync` 的精确值。

### 6.13 TA invoke 已成功；卡在 cmd 0（`094674fe4`）

上一条发现 libteec 的 16 字节 token 在 6.18 上是全 0，而
`fill_invoke_token` 无条件把它合并进 session token，**把 open 响应里 TEE
发的 CA token（token[0..15]）覆盖成了 0**。加一个「libteec 非零才合并」的
判断后：

- `inv: id=0x29 pt=0x53`（`param_types=0x53` 与 UOS 完全一致，scramble 后
  `op=0x4b58187a`）；
- **前两条 TA invoke（cmd 0x66 / 0x29）被 TEEOS 正常完成**，daemon 继续
  发送后续命令。

当前新阻塞是 **cmd 0**（`pt=0x3`，VALUE_INOUT）：TEEOS 不完成它，驱动重试
直到 10000 次上限（约 176 秒）后超时，daemon 继续到 cmd 3 后退出。
UOS 上 cmd 0 在 open 之后很快完成。下一步要在 UOS 上抓 cmd 0 的真实
smc_cmd/operation（尤其是 `params[0].value` 和 `started`），和 6.18 对比。

### 6.14 DBus 策略补全；`fpc_tac_init_lib` 成为最后阻塞

两处进展：

- **DBus 策略**：6.18 根缺 `/etc/dbus-1/system.d/com.huawei.Fingerprint.conf`，
  dbus-daemon 拒绝 `fingerprint_daemon` 拥有 `com.huawei.Fingerprint`
  （`hw_log.txt`：`Connection ... is not allowed to own the service`）。
  从 UOS 拷入策略与 activation 文件后，`busctl` 能看到服务名。仓库里已把它
  做成 `system/fingerprint/dbus/`，由 `install.sh` 安装。
- **干净启动下 TEE 全通**：冷启动后 `teec_init` 仅 49ms 就 OK，
  `fpc_tac_open`、`fpc_tac_set_os_platform`、`fpc_tac_send_set_arbitrary_data_cmd`
  全部成功（TA 已在 TEE 中缓存，不必重新 10s 加载）。

剩下的唯一阻塞是 TA 命令 **`cmd 0`（`fpc_tac_init_lib`）**：

- `param_types=0x3`（VALUE_INOUT），`params[0].value` 的 a/b 均为 0，
  session `0xE0001`，与 UOS 一致；
- UOS 上它在 674ms 内完成；6.18 上 TEE 永不返回（`doing_bitmap` 卡住），
  而且一旦卡住会**永久污染 TEE 命令队列**，后续 `SET_CA_HASH`、
  第二次 open session 全部跟着卡死，只能重启；
- 临时在驱动里跳过 `cmd 0`，daemon 会立刻报
  `fpc_tac_init_lib fpc_tac_send_cmd failed with retval: 9`，
  说明这条命令必须由 TA 真正应答。

下一步要查 `fpc_tac_init_lib` 在 TA 里做什么（安全 SPI / 传感器初始化 / SFS），
以及为什么 6.18 的 TEE 环境下它会挂住。TA 文件 `a32b3d00-...sec` 两边都是
1361856 字节，加载是完整的。

### 6.15 打通！缺的是 `/data`（SFS 后备存储）

`fpc_tac_init_lib`（TA cmd 0）本身并不"死"，它是在初始化 **SFS（安全文件系统）**。
6.18 根上 `/data` 只是一个普通目录（`/data/vendor/log`），**没有挂载数据分区**，
所以 SFS 没有任何后备存储，TA 就永远完不成 `cmd 0`。

数据分区是 `/dev/sdd7`（`_dde_data`，UOS 里就是 `/data`），里面有：

```
/data/sec_storage_data/fp/sec_storage_data/fp   <- 指纹 SFS 数据
```

把 `/dev/sdd7` 挂到 `/data` 后（UUID `a0285613-ad2f-4bb3-a54e-3cdbcd2d938c`，
已写入 6.18 的 `/etc/fstab`）：

- 冷启动 open session 慢（约 165s，TEE 首次加载 TA）但成功；
- `cmd 0` 这次会被完成（dmesg：`cmd 0 completed by TEE despite PREEMPTED`）；
- daemon 继续 `load_template_db`、`check_template_version`，最终进入 **`worker idle`**；
- `com.huawei.Fingerprint` 稳定注册在系统总线上（`busctl` 可见，pid 为 daemon）；
- 当前唯一错误是 `libimonitor.so` 缺失，属 DSM 日志库，非关键。

也就是说，**指纹 TEE 栈在 6.18 上已经跑起来了**。剩下的是打磨：

- `cmd 0` 在 6.18 上非常慢（数十秒），驱动把 SMC 当 `PREEMPTED` 反复重试，
  daemon CPU 偏高（~40%）。UOS 上同一命令只要 674ms，需要查 6.18 的 SMC
  抢占/中断路径为什么把这条长命令打断；
- 尚未做真实按压（需要物理接触传感器）来验证录入/识别；
- 需要把 `/data` 挂载与 teecd/daemon 的启动做成可复现的开机流程。

### 6.16 SMC 抢占性能 + 录入到达"手指检测"阶段

**SMC 修复（linux-l410 `546af3607`）**：厂商 `send_smc_cmd_with_retry()` 只在
不可抢占内核上调 `cond_resched()`，而 `smp_smc_send()` 无条件调用。本内核
`CONFIG_PREEMPT=y` / `HZ=250`，于是每次 `PREEMPTED` 重试都睡到下一个 4ms tick：

| | 修复前 | 修复后 |
|---|---|---|
| `cmd 0x1b` 等命令 | 重试 935~3435 次，3.7~13.6s | 重试 1~2 次，100~166µs |

给 `smp_smc_send()` 加上和厂商一致的条件后，`smc_svc_thread` 路径的命令变成
微秒级。**但 daemon 上下文里发的 `cmd 0`（`fpc_tac_init_lib`）仍然慢**：
`SMCSTAT cmd=0x0 retries≈2900 us≈11s`，且时快时慢、偶发失败重试，是下一步
要查的点（同样的 TEE 命令，从内核线程发就快，从 daemon ioctl 上下文发就慢）。

**标定文件是必需的**：`/data/sec_storage_data/fp/sec_storage_data/fp/calibration`
下的两份 80KB 文件不能删——删掉后 TA 的 `cmd 0` 直接失败
（`codes=0xffff0000 origin=2`），`cmd 41` 也失败，daemon 无法 init。

**录入进展**：SMC 修好后 daemon 能秒级到 `worker idle`，
`DeviceProperties → ib 1 true`、`SearchDevice → b true`、`GetStatus → i 0`；
`fingerprintctl enroll` 能进入 `wait_finger_down → capture_image`，触摸被接受
（`enroll count` 累加到 2、4）。卡住的地方变成
`fpc_tac_check_finger_lost` 一直返回 **5（手指仍在）**，抬起后也不变 6，
daemon 因此无限等"手指抬起"。这是传感器/TA 层的手指检测，不是 SMC 性能：
下一个排查点是采图质量/IRQ 是否被锁存，以及正常录入时 5/6 的切换节奏。

### 6.17 `cmd 0` 慢的真正原因：没注册 TEE notify 页（linux-l410 `d047131f5`）

6.16 留下的问题是「同样的 TEE 命令，从内核线程发就快、从 daemon 上下文发就慢」。
用 `smc_debug=1`（把 `smc #0` 内部耗时和循环外耗时分开计时）量出来的结果推翻了
"调用上下文"假设——**时间全在 TEE 里**：

```
SMCRETRY n=106 cmd=0x0 ret=0xb2000009 exit=0x1 ta=0x0 tgt=0xffffffb26e526000 \
         cpu=6 in_smc_us=3996 round_us=4000
```

每一轮 `in_smc_us ≈ 3996µs`、`round_us ≈ 4000µs`：NS 侧只花了 4µs，TEE 跑满
一个 4ms tick 就 `SMC_EXIT_PREEMPTED` 交还一次。`smc_svc_thread` 的 `cmd 0x1b`
是 `in_smc_us=23 round_us=23`——它不是"上下文更快"，而是**它本来就短**，4ms
内就跑完了。

所以 `cmd 0` 慢 = TA 在安全世界里空转。对比 UOS 4.19 的同一命令：

| 指标 | UOS 4.19 | 6.18（notify 关闭） |
|---|---|---|
| `end INIT_CMD_ID` 耗时 | 0.674s | 210s（多轮 5~14s 拼起来） |
| daemon `stime` 累计（=TEE CPU） | 0.68s（68 jiffies @HZ=100） | ~23s（5740 jiffies @HZ=250） |
| `Load TA took` | — | 1.09s（且每次重来） |

**根因是 6.18 侧把整个 `tz_spi_init()` 跳过了**（`06fbaba82`，当初为了避免
openEuler 版注册命令 30s 超时）。`tz_spi_init()` 做两件事：把一页 notify 内存
（`GLOBAL_CMD_ID_REGISTER_NOTIFY_MEMORY`）注册给 TEE，并申请 TEE→NS 的
安全 SPI 中断（本机 GICv3 **376**，`/proc/interrupts` 里名为 `tc_ns_client`）。
少了它，TEE 就没有任何办法告诉 NS "正在跑的 TA 需要你注意"，长命令只能退化成
"每个 tick 空转一轮"。

修正（`d047131f5`）：Kirin 990 也执行 `tz_spi_init()`（与 4.19 厂商一致），
`TC_NS_CLIENT_IOCTL_REGISTER_NOTIFY_MEMORY` 现在返回成功。结果：

| | 修复前 | 修复后 |
|---|---|---|
| `cmd 0` 单次 | retries 111~3574，0.29~14s | retries 3~109，10~415ms |
| `fpc_tac_open → end INIT_CMD_ID` | 210s | **0.62s** |
| `Load TA took` | 1096062µs | 63.6ms |
| `tc_ns_client` 中断 | 未注册 | 已注册，init 期间触发 8~9 次 |

修复后每次 `cmd 0` 依然是 4ms 一轮，但总轮数=350 左右（约 0.62s），和 UOS 的
0.68s 完全对得上，说明 ABI/数据面已经正确，之前缺的只是 notify 通道。

**新增模块参数**（都在 `tzdriver.ko` 上，`/sys/module/tzdriver/parameters/`）：

| 参数 | 默认 | 作用 |
|---|---|---|
| `kirin990_notify` | `Y` | 是否在 Kirin 990 上注册 notify 页 + `tc_ns_client` 中断。`=0` 可复现旧的 210s |
| `kirin990_tlogger` | `N` | 是否注册 TEEOS log 内存（`GLOBAL_CMD_ID_REGISTER_LOG_MEM`），用于抓 TEE/TA 日志 |
| `smc_debug` | `0` | `1`=打印每轮 `in_smc_us/round_us`（前 24 轮）；`2`=再额外 trace 每条 TA/global 命令（`SMCCMD`） |

`smc_debug=2` 的 `SMCCMD pid=... cmd=0x.. type=.. ret=..` 是排查 HAL 状态机的
主要工具，`type=0` 是 TA 命令、`type=1` 是 global 命令。

### 6.18 录入时 5/6 的真实节奏（`check_finger_lost`）

`fpc_tac_check_finger_lost` = TA cmd **0xa**，`fpc_tac_send_get_uint32_cmd()` 的
返回值取的是 `params[0].value.b`（`value.a` 通过指针返回）。把 6.18 上的完整
日志按时间排开，正常节奏是这样的（10:39 那次录入）：

```
capture_image_handle                       ← 采图完成
wait_finger_up_common
  fpc_tac_check_finger_lost → 5            ← 手指仍在（30ms 返回）
  fpc_tac_check_finger_lost → 5
  fpc_tac_check_finger_lost → 5
  fpc_tac_check_finger_lost → 6            ← 手指抬起（这条会阻塞等待）
wait_finger_up FPC_LIB_FINGER_LOST
```

也就是说 **5=手指还在、6=手指已离开**，而 `wait_finger_up_common`
（libfingerprint `0x180f0`）是这么循环的：`wait_finger_up → wait_finger_down →
check_finger_lost`，只有拿到 6 才退出，否则回去再等下一次按下。所以"一直返回 5
+ daemon 无限等"的观感有两种可能，需要实测区分：

1. 手指抬起后 TA 仍报 5（真缺陷，传感器 latch/采图没清状态）；
2. 5 是"手指还在"的正常回答，daemon 其实在等下一次按下——历史日志里
   `wait_finger_down took 5418/62855/98548/118313 ms` 对应的是两次触摸之间的
   间隔，本来就该是几十秒。

可对照的数据点：抬起后第一次 `check_finger_lost` 若已经离手，是**30~55ms** 就
返回 6（10:39:50、10:42:04、11:53:55 三次），说明 TA 的离手检测本身可以很快。
所以下一次实测要记录的是「抬起时刻 → 返回 6 的时刻」的差，以及 `smc_debug=2`
下 0xa 前后还有哪些 TA 命令。

另外，`fpc_ree_device_wait_irq` 之后紧跟 `fpc_tac_check_irq_status`，说明
"等手指按下"是 NS 侧等 GPIO IRQ（`/proc/interrupts` 的 `fa8b1000.gpio 2 Edge
fingerprint`）+ TA 查询确认两步；4.19 厂商的 `fingerprint_irq_handler`
（反汇编 `0xffffff8008e4dac0`）只做 `gpio_to_desc/gpiod_get_raw_value`、
`pm_wakeup_ws_event`、`sysfs_notify("irq")`，**并不直接通知 TEE**，所以这一步
我们现在的桩驱动（`drivers/misc/huawei-fingerprint/`）行为是等价的。

### 6.19 录入 100% 后 `end_enrol` 失败：SFS 的 fs agent 没接上（linux-l410 `107ff7b13`）

6.18 上录入能一路到 `g_progress = 100`、`enroll complete!`，但最后一步失败：

```
14:25:53.091 fpc_tac_set_uuid, retval: 0
14:25:53.092 fpc_tac_end_enrol
14:25:53.094 fpc_tac_end_enrol fpc_tac_send_cmd failed with retval: -69
14:25:53.095 fp_enroll_result_handle
14:25:53.096 fp_enroll_result_handle failed -38
```

`-69` 不是驱动错误，而是 TA 写回操作参数的失败码：`libfingerprint`
`fpc_tac_send_cmd()` 成功时返回 `operation.params[1].value.a`（TA 写的
`0xffffffbb`），所以 SMC 层 `SMCCMD ... ret=0` 看起来一切正常。
`/data/sec_storage_data/fp/sec_storage_data/fp/` 里也始终只有 `calibration/`，
模板没落盘。

对比 teecd（iTrustee 的 fs agent，SFS 的真正后端）的 I/O 找到了根因：

| | UOS 4.19（正常） | 6.18（修前） |
|---|---|---|
| `rchar` | 1054292 | **33523** |
| `wchar` | 327756 | **51** |
| `write_bytes` | 335872 | **0** |

也就是说 TA 的 SFS 请求根本没到 teecd。两个原因：

1. **`REGISTER_AGENT` 被跳过**（`e53800f11`）。当初的理由是"Kirin 990 TEE
   永不完成这条命令，teecd 会 hang"——那其实是同一轮
   notify 页缺失（见 6.17）造成的。反汇编 4.19 厂商内核确认它**会**给每个新
   agent 发这条命令：`tc_ns_register_agent`(`0xffffff8008e03370`) →
   `register_agent_to_tee`(`0xffffff8008e01940`)，cmd id `6`、
   `paramtypes=0x11`、`params[0]`=buffer 物理地址、`params[1].value.a`=size，
   4.19 的 ioctl 结构里压根没有 `user_agent` 这个概念。notify 修好后这条命令
   正常返回，teecd 也不再 hang。恢复后 teecd 注册了三个 agent：
   `0x46536673`(FSfs) / `0x4d495343`(MISC) / `0x4c4f4144`(LOAD)。
2. **agent 键值 nsid 不一致**。`init_nsid_vmid()` 给 `dev_file->nsid` 赋
   `PROC_PID_INIT_INO`，但 Kirin 990 的 102 字节 wire 命令里**没有 nsid 字段**
   （`proc_tc_ns_smc()` 强制发 0），所以 TEE 回来的 agent 请求带的是 `nsid=0`：

   ```
   init_agent_context: agent 0x46536673 nsid 0x0 vmid 0x0 not exist
   ```

   `find_event_control()` 按 `is_same_group(nsid,...)` 匹配，永远找不到 teecd
   注册的那个 `(agent_id, PROC_PID_INIT_INO)`。修法是在该 TEEOS 上把
   device file 的分组统一成 0（`init_client_group()`）。

修完实测（冷启动，`end INIT_CMD_ID` 仍是 0.65s）：

| | UOS 4.19 | 6.18 修后 |
|---|---|---|
| `agent ... not exist` | 0 | **0**（修前 7+） |
| teecd `rchar` | 1054292 | **1075203** |
| teecd `wchar` | 327756 | **327731** |
| teecd `write_bytes` | 335872 | **335872** |

即 SFS 的读写路径现在和 UOS 一致（boot 时 teecd 就会读/写
`/data/sec_storage_data/fp/sec_storage_data/fp/calibration/*`）。

**新增模块参数**：`agent_register_user`（默认 `Y`，与 4.19 厂商一致；
`=0` 可复现旧的 end_enrol 失败）。


### 6.20 对接 fprintd：`net.reactivated.Fprint` 替身服务

**为什么不是给 libfprint 写驱动**：本机 SPI1 归 TrustZone，用户态拿不到传感器图像；
采图和比对都在 TA 里完成，只有华为 daemon（`com.huawei.Fingerprint`）能驱动它。
libfprint 的驱动接口是私有 API、必须编进 libfprint；而 fprintd 的 D-Bus 接口是稳定
公开的，KDE/GNOME 设置、`fprintd-*` 命令行、`pam_fprintd`（登录/sudo/锁屏）都用它。
所以这里实现一个 **fprintd 替身**（own `net.reactivated.Fprint`），把请求转给华为 daemon。

实现：`system/fingerprint/fprintd-shim/l410-fprintd-shim.py`（python3-gi），
接口签名照抄 fprintd 1.94.5 的 `src/net.reactivated.Fprint.{Manager,Device}.xml`。

| fprintd 调用 | 华为 daemon 调用 |
|---|---|
| `Claim(user)` | `StartSession` + `SearchDevice` |
| `Release()` | `Close` |
| `EnrollStart(finger)` | `Enroll(template_db_path, user)`，进度从 `fp_hal.log` 的 `Enrol took … (p: N)` 实时换算成 `enroll-stage-passed` |
| `VerifyStart(finger)` | `Identify(user)`（在 TA 里阻塞到有手指） |
| `ListEnrolledFingers` | `/var/lib/l410-fprint/enrolled.json`（daemon 没有“列出模板”的接口） |
| `DeleteEnrolled*` | 只清本地记录（daemon 没有删除接口，模板仍在 TEE 的 SFS 里） |

设备属性：`name` = 传感器名，`scan-type` = `press`，`num-enroll-stages` = 12
（TA 每张接受图像 +8%，100/8≈12），`finger-present` 读
`/sys/bus/platform/devices/fingerprint/irq`，`finger-needed` = 是否有动作在跑。

部署（真实 fprintd 被 mask，D-Bus 激活指向替身）：

```
sudo install -m 755 l410-fprintd-shim.py /usr/local/sbin/l410-fprintd-shim
sudo install -m 644 l410-fprintd-shim.service /etc/systemd/system/
sudo install -m 644 net.reactivated.Fprint.service /usr/share/dbus-1/system-services/net.reactivated.Fprint.service
sudo systemctl mask fprintd.service
sudo systemctl enable --now l410-fprintd-shim.service
```

`/usr/share/dbus-1/system-services/net.reactivated.Fprint.service` 会被换成指向替身，
D-Bus 激活（包括 `pam_fprintd` 的首次调用）都会拉起替身。

验证（真 fprintd 客户端，无需改任何客户端代码）：

```
$ fprintd-list zhtsg
found 1 devices
Device at /net/reactivated/Fprint/Device/0
Fingerprints for user zhtsg on Huawei L410 power-button sensor (iTrustee TA) (press):
 - #0: right-index-finger
```


#### 6.20.1 KDE 设置里"添加指纹"可用；两条踩坑记录

**KDE 侧实测通了**：Plasma 6.3.6 的 Users KCM（`kcm_users.so` 引用
`EnrollStart`/`VerifyStart`/`ListEnrolledFingers`）能看到设备、能 `Claim` 并
`EnrollStart`，替身日志里每次调用都清晰可见：

```
device call Claim('') from zhtsg
device call EnrollStart('right-middle-finger') from zhtsg
```

**踩坑 1（替身 bug，已修）**：`_enroll_worker` 里 `finally: cancel.set()` 先置位，
后面又用 `not cancel.is_set()` 判断成功，导致**录入真的到 100% 也永远发不出
`enroll-completed`**，KDE 就一直显示"录入中"。修法：先读一次 stop 标志再置位。
daemon 侧的日志可以确认真录成功了：`fp_enroll_e100_handle` → `fpc_tac_end_enrol`
→ `fp_enroll_result_handle completed`，SFS 里的模板库从 70848 涨到 86208 字节。

**踩坑 2（无法删除已录入指纹）**：重复录同一根手指时 daemon 报
`[Huawei Enroll Fingerprint] template already exist! result = 4`。厂商这套栈
**没有任何删除入口**：

- D-Bus 方法全表（从 `fingerprint_daemon` 的 vtable 字符串按序取出）：
  `StartSession / DeviceProperties / ClearPovImage / SearchDevice / GetStatus /
  Close / Reload / Enroll / IdentifyWithMultipleUser / Identify` —— 没有
  Delete，也没有 List。
- `Reload(int)` 只是"刷新模板库"（`HuaweiRefreshFingerprint()` 把 int 原样传给
  `CommonDriverRefreshTemplate()`，那个函数根本不读参数），实测 0/1/2/3/4/5/99
  全部返回 `-4`，模板文件数不变。
- 模板的权威副本在 TEE 里：删掉 `/data/sec_storage_data/fp/data/fpc/*` 后，
  daemon 重启会**连 mtime 一起原样恢复**；连重启（TEE 缓存清空）之后仍然是
  原始文件 —— NS 侧那份只是镜像。
- 真正的删除在 Android HAL 层：`CommonDriverDeleteFp` /
  `Device_Delete_Fingerprint`（`libhwFingerprint.so` 导出）→
  `fpc_tac_send_delete_fingerprint_set`（TA 命令）。UOS 的控制中心走的是 HAL
  （binder）那条路。要做"删指纹"要么写个调 `libhwFingerprint` 的小工具
  （需先停 daemon 让出 TA 会话），要么逆向 TA 的删除命令。


#### 6.20.2 实测：KDE 设置可用，锁屏受 `pam_kwallet5` 阻塞

**KDE 设置（Users KCM）验证通过**：能列出设备、`Claim` + `EnrollStart`，整轮录入
（8~20 次轻触）走完 `fp_enroll_e100_handle → fpc_tac_end_enrol →
fp_enroll_result_handle completed`，模板库 70848 → 86208 字节。

**锁屏（kscreenlocker 6.3.5）的实测结论**（都是实机日志，不是推测）：

1. KDE 6.3 的锁屏是「密码框 + 指纹提示并存」，没有 UOS 那种指纹/密码 tab。
2. 它把指纹放在 **non-interactive PAM 事务** `kde-fingerprint` 里跑（greeter 二进制
   里有 `PamAuthenticators` / `NoninteractiveAuthenticatorType = None|Fingerprint|Smartcard`）。
3. `/usr/lib/pam.d/kde-fingerprint` 里除了 `pam_fprintd` 还有 `pam_kwallet5`。
   指纹成功时没有密码，`pam_kwallet5` 于是去要钱包密码：
   ```
   pam_fprintd(kde-fingerprint:auth): Verify result: verify-match (done: 1)
   pam_kwallet5(kde-fingerprint:auth): Couldn't get password (it is empty)
   ……然后事务卡住 59 秒 / 弹框，greeter 收不到成功……
   ```
   这就是"摸完还得点箭头"的直接原因。
4. **把 `pam_kwallet5` 从那个栈里删掉会让 greeter 干脆不启动指纹鉴权**
   （日志里只剩 smartcard 的 `pam_sss`，替身一次调用都收不到），所以不能删。

因此替身改成：**识别匹配成功后自己 `loginctl unlock-session <id>`**（对 C 层用户
的所有会话），效果就是"摸一下直接回桌面"，与 KDE 的事务是否卡住无关。相关代码在
`fprintd-shim/l410-fprintd-shim.py` 的 `unlock_locked_sessions()`。

**PAM 最终布局**（`system/fingerprint/install.sh` 已固化）：

| 文件 | 内容 | 作用 |
|---|---|---|
| `/etc/pam.d/common-auth` | **无** `pam_fprintd` | 密码事务保持纯密码：否则锁屏的密码事务会 10s 超时判失败并触发钱包 |
| `/usr/lib/pam.d/kde-fingerprint` | plasma 自带 `pam_fprintd` | 锁屏发起指纹识别的入口（不要删 `pam_kwallet5`，见上） |
| `/etc/pam.d/sudo` | `auth sufficient pam_fprintd.so max-tries=1 timeout=10` | 本机终端的 sudo 可用指纹，失败/超时自动回退密码 |

**踩坑备忘（替身侧，全部已修）**：

- `Properties.Get` 参数取错（把接口名当属性名）→ pam_fprintd 读不到 `scan-type`（-22）
- `VerifyFingerSelected` 必须在 `VerifyStart` **返回后**再发，否则 pam_fprintd 判
  "Unexpected ... signal" 丢弃
- 锁屏会并发发起两个事务（`Claim` ×2、`VerifyStart` ×2）：`Claim` 必须幂等，
  `VerifyStart` 在已有活着的 worker 时 join，而不是报 `AlreadyInUse`
- greeter 死掉时不会发 `VerifyStop`：残留的 `action="verify"` 会吞掉下一次请求，
  所以 `Claim` 要清残留 action，识别失败也要立刻复位
- 每次 `Claim` 先 `Close()` 重置厂商会话，否则 daemon 卡在上一次的 identify 里，
  下一次 `VerifyStart` 直接 `Device already in use`
- `pam_fprintd` 会跳过远程会话（`sd_session_is_remote`），所以 PAM 测试必须在
  本地控制台/锁屏做，SSH 里测不出来（会直接走密码）


#### 6.20.3 删指纹的工具（已写好、待实机验证）

`system/fingerprint/bin/l410-fp-del.c`（已交叉编译并装到远程
`/usr/local/sbin/l410-fp-del`）：用 `dlopen("libhwFingerprint.so")` 调厂商 HAL 的
`CommonInitFingerprint` / `CommonDriverGetFpNum` / `CommonDriverGetFpList` /
`CommonDriverDeleteFp`，也就是 UOS 控制中心通过 Android HAL 走的那条删除路径
（最终发给 TA 的是 `fpc_tac_send_delete_fingerprint_set`）。入口函数的原型是从符号
和反汇编推的，不是华为头文件，所以：

- `--list` 是只读的，可以先跑它确认 ABI 猜对了
- `--delete <id>` 会真的发 TA 删除命令，**参数猜错可能把整个模板库清空**，必须
  在机主在场时做，并先备份 `/data/sec_storage_data`
- 跑之前要 `systemctl stop hwfp_init` 让出 TA 会话（teecd 保持运行，TA 需要它的
  fs agent 做 SFS）

```sh
sudo systemctl stop hwfp_init
sudo LD_LIBRARY_PATH=/opt/uos-fp/lib /usr/local/sbin/l410-fp-del --account zhtsg --list
sudo LD_LIBRARY_PATH=/opt/uos-fp/lib /usr/local/sbin/l410-fp-del --account zhtsg --delete 0
sudo systemctl start hwfp_init
# 验证（不需要触摸）：模板条数应减 1
sudo grep -a primary_indices_count /var/log/fp_kirin/fp_hal.log | tail -1
```


**HAL 层逆向结论（2026-10-23 静态分析，供下一步用）**

- `libhwFingerprint.so` 里有一个驱动 ops 表（全局指针 + 0x40 偏移），
  `[+72]` = get_num、`[+80]` = delete：
  - `CommonDriverGetFpNum(dev, int *num)`：只校验 `dev != NULL`（值本身不用），
    然后调 `[+72]`、把结果写进 `*num`，返回 0 或 -1。**这是只读的，可以先用它验证 ABI。**
  - `CommonDriverDeleteFp(dev, X)`：校验两个参数非 NULL，然后 `mov x0, X; br [+80]`
    —— 也就是把第二个参数**原样**当作驱动删除函数的第一个实参传进去。
    所以 X 可能是整数 id，也可能是指针；`l410-fp-del` 目前按指针传，
    实测前要先确认（这也是它被标成"未验证"的原因）。
- `Device_Delete_Fingerprint(x)`（`DeviceDeleteFingerprintInit` + `opendir/readdir`）
  做的是**扫描并清理 NS 侧模板库目录**，不是发 TA 删除命令，所以它单独用没用。
- 真正发给 TA 的是 `fpc_tac_delete_fingerprint_set()` →
  `fpc_tac_send_delete_fingerprint_set()`（`libfingerprint.so` 导出）。

**结论**：删指纹仍然要"在机主在场 + 先备份 `/data/sec_storage_data`"的前提下试
`l410-fp-del`；如果 `--list` 的 ABI 不对，就先修 `--delete` 的参数形态再动。
考虑到旧模板本身无害（那根手指也能解锁），这件事排在锁屏/PAM 回归之后。


### 6.21 传感器 -99 的根因：报给 TA 的复位脚编号错了（linux-l410 `dd115be17`）

**现象**：6.18 上 `fpc_tac_finger_detect` 恒 `-99`、指纹 IRQ 计数 0；同一硬件在
UOS 里返回 `0`。软重启、硬断电、复位脉冲、换 DAEMON 都没用。

**定位**：`kirin990_tlogger=1` 打开 TEE 日志（`/dev/teelog`，二进制环缓冲，用
`cat /dev/teelog | tr -c '[:print:]\n' '\n' | grep -aE '.{8,}'` 读）后一目了然：

```
[HM] g_os_platform = 3, fpc reset_gpio_pin = 199, irq_gpio_pin = 234, spi_cs =10, spi_num = 1
fp_init_sensor: Hello fpkit
[platdrv] not find the spi num
gpio_read_write ... error  -> do_timing_node failed -7 -> func_init_sensor_prepare failed -7
fp_init_sensor: Product_id=255 Sensor_id=3658     (255 = 0xFF = 无效)
libgxfp_set_fdt_down ... LogicContext is null
fp_init_finger_detect: Failed and error=-99
```

TA 的 `fp_init_sensor` 用 `FP_IOC_CMD_GET_DEVICE_INFO` 拿到的引脚号去做**传感器上电
时序**（经 TEE 的 secure-GPIO 驱动）。固件 DT 里那句陈旧的
`fingerprint,reset_gpio = <199>` 被驱动原样报了过去，而 199 和传感器无关：上电
时序失败 → 传感器模块从未初始化（`LogicContext is null`）→ 之后一切命令 `-99`。

**厂商编号是 `bank * 8 + line` 的 "custom" 编号**（UOS 日志 `fpc reset_gpio_pin =
281, irq_gpio_pin = 234`）：

| 线 | DT 节点 | 计算 | 报给 TA 的值 |
|---|---|---|---|
| reset | `fa8b7000` line 1 | 35*8+1 | **281** |
| irq | `fa8b1000` line 2 | 29*8+2 | **234** |

（Linux 全局号 793/746 也不行，试过，TA 一样失败。）

**修法**：`l410/dt/fixups.d/09-laptop.dtsi` 里覆盖
`fingerprint,reset_gpio = <281>` / `fingerprint,irq_gpio = <234>`，驱动
`FP_IOC_CMD_GET_DEVICE_INFO` 如实上报。修好后 TEE 日志出现
`func_init_sensor: module_info: 23100501TC38A1109051209P...`（真实模组 ID），
`finger_detect` 恢复 0，IRQ 开始计数。

### 6.22 中断握手：enable 要返回 1、`irq` 属性语义要对、probe 后先关中断

> **2026-10-24 更正**：本节原来的“`irq` 属性要锁存”是错的，正是它让 HAL 自激。
> 正确语义是**实时电平**，见 §6.23。下面保留当时的推理过程，表格已按最终结论修正。

对照 strace 出来的 HAL 行为（`fpc_ree_device_wait_irq()` 依次做
`read sysfs irq` → 读到 0 才 `poll(POLLPRI)`，一圈由 HAL 用
`ENABLE_IRQ(0x6601)` / `DISABLE_IRQ(0x6602)` 包起来）逐项对齐厂商驱动：

| 项 | 厂商驱动 | 我们（修前） | 现在 |
|---|---|---|---|
| `ENABLE_IRQ` 返回值 | **1**（`mov w0,#1` 后 ret） | 0 → HAL 认为没武装，20ms 重来 | 1 |
| `irq` sysfs 属性 | **实时电平**（手指压住=1，空闲=0） | 实时电平 OR 锁存 | **只回实时电平**（`0157cfc6f`） |
| probe 后的中断状态 | 厂商在 probe 就使能（UOS 启动期能看到 96 次脉冲） | 一直使能 | `disable_irq`，`irq_enabled=0` |
| 中断 flags | `IRQF_ONESHOT\|IRQF_EARLY_RESUME\|TRIGGER_RISING`(0x6001)；`dev->@808==1` 时双边沿(0x6003) | `TRIGGER_RISING\|ONESHOT` | 同（未做 0x6003 分支） |

修完后空闲状态与 UOS 完全一致（`irq_enabled=0`、计数 0），等待期间 daemon 正常
`enable→poll→disable` 翻转（实测 0/1 交替）。

**仍未直接验证的一环**：`fpc_tac_check_irq_status` 在真人触摸时是否像 UOS 那样回 **0**。
自激循环已于 2026-10-24 修掉（§6.23），僵持点不再是“每 20ms 重来一次”，而是“没有任何
手指去打破 `poll()`”。

**UOS 侧数据是好的**：同一套模板在 UOS `Identify` 得到
`result: 0 score: 10000 index: 1 coverage: 100 quality: 84`。

**定量对照（2026-10-24 晚）**：

| 指标 | UOS 4.19 | 6.18 |
|---|---|---|
| 一整轮 identify 的 `TA_fp_tee_init_finger_detect` | 4 次 | 每 ~20ms 一次 |
| 触摸前 34 秒内的 TA 日志 | 0 行 | 几百行 |
| 10 秒内 `fpc_tac_finger_detect` | — | 468 次，与 IRQ 增量完全相等 |
| `fpc_tac_check_irq_status` | 0（触按时） | 恒 6 |

即 6.18 上**每次武装 FDT 都会换来恰好一个 IRQ**，HAL 的 poll 立刻返回 → 查 TA 无手指
→ 再武装，自激循环；UOS 上武装后传感器不再发中断，直到真有手指。问题不在 HAL 的
循环（它对"中断但不是手指"本来就是这么重试的），而在"为什么每次武装都产生一个中断"。

另外 UOS 的 TA 日志里有一行 6.18 从未出现的：
`_IoHubExec is fdt cmd , must wait for intr after don't free cmd` —— 说明 UOS 上这条
SPI 命令会保持挂起等中断。

**当时列出的下一步**（`0x6003` 双边沿、`irq_custom_scheme`、pinctrl 等）最后都不是
原因，见 §6.23。

**调试备忘**：`/dev/teelog` 是二进制环缓冲（`cat /dev/teelog | tr -c '[:print:]\n'
'\n' | grep -aE '.{8,}'`，先 `cat /dev/teelog >/dev/null` 清空）；看中断率用
`/sys/devices/platform/fingerprint/irq_count`（只读、不清零）或 `/proc/interrupts`，
**别**用脚本轮询 `irq`（它现在回实时电平，以前的版本会清锁存、把事件从 daemon
手里抢走）；UOS 的 daemon 日志在 `/data/var/log/fp_kirin/`。

### 6.23 自激循环的根因：`irq` 属性应当是“实时电平”，不是“锁存”（`0157cfc6f`）

**现象**：6.18 上 identify 时 HAL 每 ~20 ms 走一圈：
`ENABLE_IRQ(0x6601)` → 读 sysfs `irq` → TA `check_irq_status`（恒 6）→
`DISABLE_IRQ(0x6602)` → TA `finger_detect`；`fpc_tac_finger_detect` 468 次/10 s，
与 IRQ 增量一一对应。

**strace 出来的真实顺序**（`strace -X raw -e trace=ioctl,openat,read`，一圈）：

```
.960670 ioctl(6, 0x6602, 0)        = 0   DISABLE_IRQ
.961470 ioctl(8, 0xc0b07403, ...)  = 0   TA finger_detect（武装 FDT）
   ...16 ms...
.977718 ioctl(6, 0x6601, 0)        = 1   ENABLE_IRQ
.978464 openat(dir, "irq"); read → "1"   HAL 读 irq 属性
.978543 ioctl(8, 0xc0b07403, ...)  = 0   TA check_irq_status → 6
```

关键：**武装发生在 ENABLE 之前**，而传感器对每条 FDT 命令都会把 IRQ 线脉冲拉高一次。
那一刻中断是关着的，脉冲变成 GPIO 控制器里的一个 pending edge，`enable_irq()` 一解除
屏蔽就补投递给我们。我们把它锁存进 `irq` 属性并报 `1`，HAL 于是认为“手指来了”，去问
TA（TA 里当然没有手指）拿到 6，再关中断、再武装——自激。

**UOS 4.19 侧的对照**（2026-10-24 自动采集，原始数据在远程机
`/data/l410-uos-probe/`）：

| 观测 | UOS 4.19 | 6.18（修前） |
|---|---|---|
| HAL 启动到空闲的 IRQ | 96（传感器上电/初始化 SPI 命令的脉冲；驱动 probe 就使能了中断） | 0（我们在 probe 把中断关了） |
| 空闲等待时的 IRQ | 0（`poll()` 一挡就是 31 分钟，见 fp_hal.log 10:24 那条） | ~48/s |
| `fpc_ree_device_wait_irq` 日志 | 一次，之后阻塞 | 每 20 ms 一条 + `error irq ,should wait finger down` |
| `.../fingerprint/irq` | **0**（空闲；不是锁存） | 1（锁着一个 pending edge） |
| `.../fingerprint/irq_enabled` | 0（空闲） | 0/1 翻转 |
| PIN65（GPIO746，IRQ）IOMG / IOCG | `0x00000000` / `0x00000000` | 完全相同 |
| PIN111（GPIO281，reset）IOCG | `0x00000001` | 完全相同 |
| 厂商驱动 claim 的 GPIO | 只有 reset（`pin 111 → fa8b7000.gpio:281`），IRQ 脚不 claim | 两者都 claim |

即：**引脚复用和上下拉两边逐位相同，不是 pinctrl 问题**；TA 侧在 UOS 上其实也会打出
`_IoHubExec is fdt cmd , must wait for intr after don't free cmd`，只是 HAL 根本不进那个
循环。差别只在“`irq` 属性报什么”。厂商驱动的这个属性就是**线的实时电平**：没有手指 =
0，手指压住（传感器保持拉高）= 1。HAL 正是按这个语义写的：`ENABLE → 读 → 读到 0 才
poll(POLLPRI)`，`sysfs_notify()` 负责唤醒。

**修复**：`irq_show()` 只回 `gpiod_get_value()` 的实时电平；锁存标志仍保留给
`FP_IOC_CMD_GET_IRQ_STATUS`（这个 HAL 不用它），`ENABLE_IRQ` 时照旧清锁存/计数；
新增只读属性 `irq_count`（累计中断次数，读不清零）——看脉冲率不用再去抢 `irq`。

**实测效果**（同一台机、同一套模板、无人触摸）：

```
一次 identify：irq +1，irq_count +1，之后 HAL 停在 fpc_ree_device_wait_irq
再等 30 秒：IRQ +0，日志无新行          ← 与 UOS 的空闲状态一致
quick.sh：195 pass / 1 fail（pmic.rtc，见下）
```

顺手修掉的一个测试环境问题：RTC 实际按 UTC 走，但 `/etc/adjtime` 写着 `LOCAL`，
`quick.sh` 的 `pmic.rtc` 因此差 28799 s。远程机上执行 `sudo timedatectl set-local-rtc 0`
后 CPU/RTC 一致，该用例转 PASS。

**尚未验证**：真正用手指触摸 → `irq` 读到 1 → TA `check_irq_status` 是否回 0 → 采图/比对。
这一步必须机主在机器旁做：

```sh
ssh zhtsg-remote
sudo /usr/local/sbin/fingerprintctl session
sudo /usr/local/sbin/fingerprintctl identify zhtsg     # 10 秒内轻触电源键上的传感器
sudo tail -20 /var/log/fp_kirin/fp_hal.log             # 期待 check_irq_status retval: 0
                                                       # 以及 Identify took ... (result: 0 ...)
sudo cat /sys/devices/platform/fingerprint/irq_count   # 触摸一次应 +1
```


## 7. 验证与诊断测试

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
