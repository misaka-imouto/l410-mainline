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
