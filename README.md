# gpu-preflight

Linux 游戏启动前体检（NVIDIA / AMD / SteamOS / Proton / Flatpak Steam）

使用 Deepseek 进行编写

---

## 设计目标

与具体游戏无关。

* 默认只体检系统层面：驱动内核态、显存/内存、Vulkan 设备可见性
* 需要时用 `--game` / `--all-games` 追加检查某个（或全部）Steam 快捷方式：Proton 前缀、启动项、BepInEx/Doorstop 注入链
* 只读不写：不改任何配置文件、不装包，所以在只读根文件系统（SteamOS）上也能跑

## 用法

```bash
./gpu-preflight.sh                        # 只体检系统
./gpu-preflight.sh --list-games            # 列出所有 Steam 快捷方式及风险
./gpu-preflight.sh --all-games             # 扫描所有快捷方式的注入链风险
./gpu-preflight.sh --game 关键词           # 系统体检 + 该游戏检查（匹配名称/路径）
./gpu-preflight.sh --game 关键词 -l        # 检查通过后启动它
./gpu-preflight.sh --game 关键词 -l -y     # 有警告也不询问，直接启动
./gpu-preflight.sh -v                      # 详细输出
./gpu-preflight.sh -q                      # 安静模式：只输出问题
./gpu-preflight.sh --no-vulkan             # 跳过 vulkaninfo（更快）
./gpu-preflight.sh --no-color
./gpu-preflight.sh -h                      # 帮助
```

退出码：`0` = 一切正常　`1` = 有警告（可以试，但注意）　`2` = 严重（如驱动已损坏，先重启）

## 检查项

1. **环境与显卡拓扑**：系统/内核、GPU 列表、`boot_vga`、哪块卡在驱动显示器、`nvidia_drm` 参数、混合显卡提示（`-v` 显示细节）
2. **显卡驱动内核态**（按平台自动选分支）
   * NVIDIA：`NVRM` 两档判定 + `Xid` 故障码统计 + 内核模块与用户态版本一致性
   * AMD：`amdgpu` 的 GPU reset / MES 无响应（致命）、ring 超时 / 页错误（警告）
3. **显存 / 内存 / 交换**：支持多 GPU；`nvidia-smi` 不可用时提示驱动异常；zram（SteamOS/Deck 默认）结合可用内存判断，不误报
4. **Vulkan 设备可见性**：`vulkaninfo` 枚举失败、或有对应驱动却看不到设备都会告警
5. **游戏侧（可选）**：Doorstop 注入链、`doorstop_config.ini`、`winhttp=n,b` 覆盖、Proton 版本、前缀里的 vkd3d-proton / DXVK、自带 Agility SDK 提示

## 为什么需要它（真实踩坑记录，2026-09）

### A. NVIDIA 驱动内核态连锁损坏

1. 系统内存 / 显存分配失败　（`NV_ERR_NO_MEMORY` @ `system_mem.c` / `pmaAllocatePages`）
2. GPU 虚拟地址空间映射失败　（`dmaAllocMapping_GM107` / `gpu_vaspace.c`）
3. GPU channel / GSP 分配失败　（`kchangrpapiConstruct` / `GspRmAlloc`）

走到第 3 步后 vkd3d-proton 建不出 D3D12 设备 → D3D12 游戏黑屏（有声音），而且每启动一次都会往坏掉的地址空间里再叠一批映射，只会更糟。这种内核态损坏只能靠重启清除（重载 nvidia 模块 + 复位 GPU/GSP）。

### B. AMD / amdgpu（SteamOS、Steam Deck）

GPU reset、MES 无响应、ring 超时、页错误之后，本次开机内经常继续出错（黑屏、掉驱动）。脚本会在启动前拦下来，提示先重启，而不是白试一次。

### C. BepInEx / Doorstop 注入（汉化、Mod）

任何用 BepInEx/Doorstop 的游戏在 Proton 下都可能中招：Proton 默认优先加载内置 `winhttp.dll`，游戏目录里的 Doorstop 注入器不被执行 → BepInEx 不启动 → 汉化/Mod 全失效。修法是启动项加 `WINEDLLOVERRIDES=winhttp=n,b`。脚本会自动识别这类游戏并检查该覆盖（启动项或前缀注册表里都算）。

## 配置

默认值先用环境变量覆盖；若存在配置文件（默认 `~/.config/gpu-preflight.conf`）会在其后被 source，因此配置文件里请写成 `VAR="${VAR:-值}"` 这种形式，这样命令行环境变量依然优先。

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `VRAM_WARN_MIB` | `2000` | 空闲时显存占用超过此值 → 疑似泄漏 |
| `VRAM_WARN_PCT` | `80` | 显存占用超过此百分比 → 警告 |
| `RAM_MIN_MIB` | `2048` | 可用内存低于此值 → 警告 |
| `SWAP_WARN_MIB` | `4096` | 交换已用超过此值 → 警告（zram 另有判断） |
| `JOURNAL_ARGS` | `-b -k` | 内核日志范围，可设 `-b -1 -k` 检查上一次开机 |
| `STEAM_DIR` | 自动探测 | 指定后只扫这一个 Steam 根目录 |
| `STEAM_USERDATA` | 自动探测 | 指定 userdata 数字目录（多账号） |
| `XID_SERIOUS` | `48 56 62 74 79 94 95 109 119 120` | 视为严重的 Xid 码 |
| `OS_RELEASE_FILE` | `/etc/os-release` | 调试/容器用 |
| `FORCE_GPU` | `auto` | `auto` / `nvidia` / `amd`，强制走某个驱动分支 |

## SteamOS / Steam Deck 支持

* 驱动检查自动切到 **amdgpu** 分支（GPU reset / MES / ring timeout / 页错误）
* **zram** 占用高不再误报：只有「zram 用得多 **且** 可用内存也低」才告警
* 明确提示 **不要手动改 `/usr`**（SteamOS 是不可变系统，改动会被系统更新抹掉），并显示 `steamos-readonly` 状态
* Steam 根目录按 SteamOS 习惯探测（`~/.local/share/Steam`、`~/.steam/steam`、`~/.steam/root`）
* 在桌面模式（Konsole）或 SSH 里直接跑即可；脚本不写任何文件

## Flatpak 版 Steam 支持

* 自动探测 `~/.var/app/com.valvesoftware.Steam/data/Steam` 与 `~/.var/app/com.valvesoftware.Steam/.local/share/Steam`
* `compatdata` / Proton 前缀在 **Flatpak 自己的 Steam 目录**里查找（不是 `~/.local/share/Steam`）
* `-l` 启动游戏时按顺序尝试：`flatpak run com.valvesoftware.Steam -applaunch` → `steam -applaunch` → `xdg-open steam://rungameid/<appid>`
* **原生 Steam 与 Flatpak Steam 可以同时存在**：脚本会全部扫描，并注明每个游戏来自哪个根目录（含 `原生 Steam` / `Flatpak Steam` / `SteamOS 内置 Steam` 标签）

## 发行版兼容性

* 需要 bash（用到进程替换 / here-string；bash 4+ 更稳）、coreutils、grep、awk、sed、sort、uniq、cut、tr。awk 只用 POSIX 特性，gawk / mawk(Debian) / BusyBox awk(Alpine) 都能跑
* 内核日志：有 systemd 就用 `journalctl`（支持 `-b` / `-b -1` 看上一次开机）；没有 systemd（Void、Artix、Alpine 等）自动退回 `dmesg` —— 非 root 读 dmesg 需要 `kernel.dmesg_restrict=0`，否则该项会提示「没做」（不代表有问题）
* 读的都是内核标准接口（`/proc/driver/nvidia`、`/proc/meminfo`、`/sys/class/drm`、`/etc/os-release`），所以 Debian/Ubuntu、Fedora/RHEL、Arch/CachyOS、openSUSE、Alpine、SteamOS 都能用；检查的可执行文件只按「命令是否存在」判断，不依赖任何包管理器
* 可选依赖（缺了只跳过对应检查，不影响其它项）：`nvidia-smi`、`vulkaninfo`(vulkan-tools)、`lspci`(pciutils)、`python3`（解析 `shortcuts.vdf`，只有 `--game`/`--all-games`/`--list-games` 需要）、`timeout`、`steam` / `flatpak` / `xdg-open`（仅 `-l` 启动用）
* 平台范围：NVIDIA 与 AMD/amdgpu 驱动检查都支持；Intel 平台仍做内存与 Vulkan 检查，驱动专属项会明确提示「未检测到」
