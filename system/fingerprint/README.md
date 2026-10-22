# 华为擎云 L410 电源键指纹与 TrustZone TEE 集成

本目录包含华为擎云 L410 笔记本电源键指纹识别在 Linux 6.18 主线内核上的用户态服务配置、规则与诊断工具。

---

## 1. 硬件架构与安全世界隔离

擎云 L410（麒麟 990）的指纹识别芯片位于键盘右上角电源键内，属于高安全级硬件隔离设计：

```
+------------------------------------------------------------------------+
|                          Normal World (Linux REE)                      |
|                                                                        |
|  [ Desktop Login / PAM ]  -->  [ deepin-authenticate / DBus ]          |
|                                         |                              |
|                              [ fingerprint_daemon ]                    |
|                                    /           \                       |
|                             [ teecd ]       /dev/fingerprint           |
|                                 |             (GPIO 199 RST,           |
|                         /dev/tc_ns_client     GPIO 234 IRQ)            |
+---------------------------------|--------------------------------------+
|                         SMC 0xC3000000+                                |
+---------------------------------v--------------------------------------+
|                         Secure World (iTrustee TEE)                    |
|                                                                        |
|  [ Huawei Fingerprint TA (a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec) ]  |
|                                 |                                      |
|                       [ SPI1 Secure Bus (fa048000.spi) ]               |
|                                 |                                      |
|            [ FPC1020/1025 Capacitive Fingerprint Sensor ]              |
+------------------------------------------------------------------------+
```

- **传感器硬件**：Fingerprint Cards AB (FPC) 电容式按压传感器（FPC1020/1025 架构，芯片识别码 `0x204`）。
- **总线安全隔离**：SPI1 控制器（`0xfa048000`）完全由 Secure World（EL3/S-EL1 iTrustee OS）控制，Normal World（Linux 内核）无法直接读写 SPI1 寄存器。
- **生物特征数据安全**：采集的指纹原始图像、特征模板（Template）均直接在 TEE 内部提取、比对与加密存储，明文指纹图像永不出安全世界。

---

## 2. 内核驱动组件

Linux 6.18 内核提供两大内核驱动支持：

1. **`CONFIG_TZDRIVER=y` (`drivers/tee/itrustee/`)**：
   - 华为 openEuler / iTrustee 客户端安全世界 SMC 网关。
   - 生成字符设备 `/dev/tc_ns_client`，负责转发用户态 `teecd` 与 TEE OS 之间的安全世界会话通道。
2. **`CONFIG_HUAWEI_FINGERPRINT=y` (`drivers/misc/huawei-fingerprint/`)**：
   - 设备树匹配节点：`compatible = "fpc,fingerprint"`。
   - 控制传感器硬件重置引脚（GPIO 199）。
   - 捕获按压触摸中断（GPIO 234，IRQ 205），通过 poll 等待队列与 sysfs 通知唤醒上层指纹识别服务。
   - 生成字符设备 `/dev/fingerprint` 与 sysfs 控制接口 `/sys/class/huawei_fp/fingerprint/`。

---

## 3. 用户态服务栈与安装

运行 `system/install.sh` 或本目录下的脚本即可完成配置：

```bash
# 执行指纹服务配置
sudo ./install.sh
```

### 服务角色：
- **`teecd.service`**：
  - 路径：`/vendor/bin/teecd`
  - 职责：TEE 守护进程，向内核 `/dev/tc_ns_client` 发送 Trusted Application 镜像（`/system/vendor/bin/a32b3d00-cb57-11e3-9c1a-0800200c9a66.sec`）并在非安全世界与安全世界之间中继请求。
- **`hwfp_init.service`**：
  - 启动脚本：`/usr/bin/hwfp_init.sh`，拉起 `/usr/bin/fingerprint_daemon`。
  - 职责：华为指纹业务守护进程，监听 `/dev/fingerprint` 中断，连接 `teecd` 执行指纹录入、匹配，并通过 DBus（`com.huawei.Fingerprint`）对外暴露统一生物认证接口。
- **`deepin-authenticate.service`**：
  - 桌面认证后端，桥接 Linux PAM（`pam_deepin_authentication.so`）与指纹 DBus 服务，实现锁屏、开机登录与 `sudo` 授权。

---

## 3.1 在 6.18 上跑 UOS 的厂商栈（调试用）

```bash
# 以 root 在 6.18 测试根上执行：起 teecd，再起 fingerprint_daemon，
# 然后打印进程、内核栈、DBus 和 tzdriver 日志
sudo /path/to/l410-mainline/system/fingerprint/run-uos-stack.sh
```

具体原理与当前阻塞（4.19 ABI 兼容层已完成，卡在 TEE 不完成用户态发起的
全局 SMC）见 `docs/hardware/fingerprint.md` 第 6 节。

## 4. 诊断与测试

运行诊断脚本检查各组件状态：

```bash
# 检查驱动节点、TA 镜像与服务状态
./test-fingerprint.sh

# 实时监测手指按压电源键指纹传感器的中断信号
sudo ./test-fingerprint.sh --monitor
```
