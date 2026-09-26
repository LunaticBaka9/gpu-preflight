# gpu-preflight
Linux 游戏启动前体检（重点覆盖 NVIDIA + Proton）
使用Deepseek进行编写

设计目标：与具体游戏无关。
    · 默认只体检系统层面：驱动内核态、显存/内存、Vulkan 设备可见性
    · 需要时用 --game / --all-games 追加检查某个（或全部）Steam 快捷方式：
      Proton 前缀、启动项、BepInEx/Doorstop 注入链

  为什么需要它（真实踩坑记录，2026-09）：
    A. NVIDIA 驱动会在内核态出现连锁损坏：
         1) 系统内存 / 显存分配失败    (NV_ERR_NO_MEMORY @ system_mem.c / pmaAllocatePages)
         2) GPU 虚拟地址空间映射失败    (dmaAllocMapping_GM107 / gpu_vaspace.c)
         3) GPU channel / GSP 分配失败  (kchangrpapiConstruct / GspRmAlloc)
       走到第 3 步后 vkd3d-proton 建不出 D3D12 设备 → D3D12 游戏黑屏（有声音），
       而且每启动一次都会往坏掉的地址空间里再叠一批映射，只会更糟。
       这种内核态损坏只能靠重启清除（重载 nvidia 模块 + 复位 GPU/GSP）。
    B. 任何用 BepInEx/Doorstop 的游戏（汉化、Mod）在 Proton 下都可能中招：
       Proton 默认优先加载内置 winhttp.dll，游戏目录里的 Doorstop 注入器不被执行
       → BepInEx 不启动 → 汉化/Mod 全失效。修法是启动项加 WINEDLLOVERRIDES=winhttp=n,b。

  用法：
    ./gpu-preflight.sh                        # 只体检系统
    ./gpu-preflight.sh --list-games            # 列出所有 Steam 快捷方式及风险
    ./gpu-preflight.sh --all-games             # 扫描所有快捷方式的注入链风险
    ./gpu-preflight.sh --game 关键词           # 系统体检 + 该游戏检查（匹配名称/路径）
    ./gpu-preflight.sh --game 关键词 -l        # 检查通过后启动它（steam -applaunch）
    ./gpu-preflight.sh --game 关键词 -l -y     # 有警告也不询问，直接启动
    ./gpu-preflight.sh -v                      # 详细输出
    ./gpu-preflight.sh -q                      # 安静模式：只输出问题
    ./gpu-preflight.sh --no-vulkan             # 跳过 vulkaninfo（更快）
    ./gpu-preflight.sh --no-color
    ./gpu-preflight.sh -h                      # 帮助

  退出码： 0 = 一切正常   1 = 有警告（可以试，但注意）   2 = 严重（如驱动已损坏，先重启）

  配置：默认值先用环境变量覆盖；若存在配置文件（默认 ~/.config/gpu-preflight.conf）
        会在其后被 source，因此配置文件里请写成 VAR="${VAR:-值}" 这种形式，
        这样命令行环境变量依然优先。
        可用变量：VRAM_WARN_MIB、VRAM_WARN_PCT、RAM_MIN_MIB、SWAP_WARN_MIB、
                  JOURNAL_ARGS（默认 "-b -k"，可设 "-b -1 -k" 检查上一次开机）、
                  STEAM_DIR、STEAM_USERDATA、XID_SERIOUS

  发行版兼容性：
    · 需要 bash（用到进程替换 / here-string；bash 4+ 更稳）、coreutils、grep、awk、sed、
      sort、uniq、cut、tr。awk 只用 POSIX 特性，gawk / mawk(Debian) / BusyBox awk(Alpine) 都能跑。
    · 内核日志：有 systemd 就用 journalctl（支持 -b / -b -1 看上一次开机）；
      没有 systemd（Void、Artix、Alpine 等）自动退回 dmesg —— 注意非 root 读 dmesg
      需要 kernel.dmesg_restrict=0，否则该项会提示跳过。
    · 读的都是内核标准接口（/proc/driver/nvidia、/proc/meminfo、/sys/class/drm），
      所以 Debian/Ubuntu、Fedora/RHEL、Arch/CachyOS、openSUSE、Alpine 等都能用；
      检查的可执行文件只按“命令是否存在”判断，不依赖任何包管理器。
    · 可选依赖（缺了只跳过对应检查，不影响其它项）：
        nvidia-smi（显存）、vulkaninfo/vulkan-tools（Vulkan 枚举）、lspci/pciutils（拓扑）、
        python3（解析 Steam shortcuts.vdf，只有 --game/--all-games/--list-games 需要）、
        timeout（coreutils，给 vulkaninfo 加超时）。
    · Steam 安装位置自动探测：~/.local/share/Steam、~/.steam/steam、
      Flatpak 版 ~/.var/app/com.valvesoftware.Steam/data/Steam（可用 STEAM_DIR 指定）。
#    · 平台范围：检查项偏 NVIDIA + Proton；AMD/Intel 平台仍做内存与 Vulkan 检查，
#      NVIDIA 专属项会明确提示“未检测到 NVIDIA 驱动”。
