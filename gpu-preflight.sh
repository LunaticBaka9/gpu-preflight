#!/usr/bin/env bash
# ============================================================================
#  gpu-preflight.sh — Linux 游戏启动前体检（NVIDIA / AMD / SteamOS / Proton / Flatpak Steam）
#
#  设计目标：与具体游戏无关。
#    · 默认只体检系统层面：驱动内核态、显存/内存、Vulkan 设备可见性
#    · 需要时用 --game / --all-games 追加检查某个（或全部）Steam 快捷方式：
#      Proton 前缀、启动项、BepInEx/Doorstop 注入链
#
#  为什么需要它（真实踩坑记录，2026-09）：
#    A. NVIDIA 驱动会在内核态出现连锁损坏：
#         1) 系统内存 / 显存分配失败    (NV_ERR_NO_MEMORY @ system_mem.c / pmaAllocatePages)
#         2) GPU 虚拟地址空间映射失败    (dmaAllocMapping_GM107 / gpu_vaspace.c)
#         3) GPU channel / GSP 分配失败  (kchangrpapiConstruct / GspRmAlloc)
#       走到第 3 步后 vkd3d-proton 建不出 D3D12 设备 → D3D12 游戏黑屏（有声音），
#       而且每启动一次都会往坏掉的地址空间里再叠一批映射，只会更糟。
#       这种内核态损坏只能靠重启清除（重载 nvidia 模块 + 复位 GPU/GSP）。
#    B. 任何用 BepInEx/Doorstop 的游戏（汉化、Mod）在 Proton 下都可能中招：
#       Proton 默认优先加载内置 winhttp.dll，游戏目录里的 Doorstop 注入器不被执行
#       → BepInEx 不启动 → 汉化/Mod 全失效。修法是启动项加 WINEDLLOVERRIDES=winhttp=n,b。
#
#  用法：
#    ./gpu-preflight.sh                        # 只体检系统
#    ./gpu-preflight.sh --list-games            # 列出所有 Steam 快捷方式及风险
#    ./gpu-preflight.sh --all-games             # 扫描所有快捷方式的注入链风险
#    ./gpu-preflight.sh --debug-steam           # 诊断：账号目录/每个 vdf/解析条数（查"读不到游戏"用）
#    ./gpu-preflight.sh --game 关键词           # 系统体检 + 该游戏检查（匹配名称/路径）
#    ./gpu-preflight.sh --game 关键词 -l        # 检查通过后启动它（steam -applaunch）
#    ./gpu-preflight.sh --game 关键词 -l -y     # 有警告也不询问，直接启动
#    ./gpu-preflight.sh -v                      # 详细输出
#    ./gpu-preflight.sh -q                      # 安静模式：只输出问题
#    ./gpu-preflight.sh --no-vulkan             # 跳过 vulkaninfo（更快）
#    ./gpu-preflight.sh --no-color
#    ./gpu-preflight.sh -h                      # 帮助
#
#  退出码： 0 = 一切正常   1 = 有警告（可以试，但注意）   2 = 严重（如驱动已损坏，先重启）
#
#  配置：默认值先用环境变量覆盖；若存在配置文件（默认 ~/.config/gpu-preflight.conf）
#        会在其后被 source，因此配置文件里请写成 VAR="${VAR:-值}" 这种形式，
#        这样命令行环境变量依然优先。
#        可用变量：VRAM_WARN_MIB、VRAM_WARN_PCT、RAM_MIN_MIB、SWAP_WARN_MIB、
#                  JOURNAL_ARGS（默认 "-b -k"，可设 "-b -1 -k" 检查上一次开机）、
#                  STEAM_DIR、STEAM_USERDATA、STEAM_USER_HOME、XID_SERIOUS、
#                  OS_RELEASE_FILE、FORCE_GPU
#
#  非 Steam 快捷方式（"右键 → 添加到 Steam"）：
#    只存在 <Steam 根>/userdata/<账号 id>/config/shortcuts.vdf，脚本会：
#      · 扫描所有 Steam 根（原生 / SteamOS / Flatpak）与**所有账号**，不只第一个账号
#      · 用 sudo 运行时自动改用 SUDO_USER 的家目录（并兜底 /home/*），避免 $HOME=/root 找不到
#      · 优先用 python3 解析；没有 python3 时用内置 coreutils 解析器（SteamOS/极简系统也能用）
#      · 读不到时用 --debug-steam 打印账号目录、vdf 大小/时间、原始条目数与解析条数
#
#  发行版兼容性：
#    · 需要 bash（用到进程替换 / here-string；bash 4+ 更稳）、coreutils、grep、awk、sed、
#      sort、uniq、cut、tr。awk 只用 POSIX 特性，gawk / mawk(Debian) / BusyBox awk(Alpine) 都能跑。
#    · 专门适配了两类环境：
#        1) SteamOS / Steam Deck（不可变系统、AMD APU、zram）：
#           - 驱动检查会自动切换到 amdgpu 分支（GPU reset / MES / ring timeout / 页错误）
#           - zram 占用高不再误报（结合可用内存判断）
#           - 提示不要手动改 /usr（改动会被系统更新抹掉），并显示 steamos-readonly 状态
#        2) Flatpak 版 Steam（com.valvesoftware.Steam）：
#           - 自动探测 ~/.var/app/com.valvesoftware.Steam/data/Steam 与 .local/share/Steam
#           - compatdata/Proton 前缀在 Flatpak 自己的 Steam 目录里查找
#           - -l 启动时优先用 flatpak run，其次 steam -applaunch，最后 xdg-open steam://
#        原生 Steam 与 Flatpak Steam 可以同时存在：脚本会全部扫描，并注明每个游戏来自哪个根目录
#    · 内核日志：有 systemd 就用 journalctl（支持 -b / -b -1 看上一次开机）；
#      没有 systemd（Void、Artix、Alpine 等）自动退回 dmesg —— 注意非 root 读 dmesg
#      需要 kernel.dmesg_restrict=0，否则该项会提示"没做"（不代表有问题）。
#    · 读的都是内核标准接口（/proc/driver/nvidia、/proc/meminfo、/sys/class/drm），
#      所以 Debian/Ubuntu、Fedora/RHEL、Arch/CachyOS、openSUSE、Alpine、SteamOS 都能用；
#      检查的可执行文件只按"命令是否存在"判断，不依赖任何包管理器，也不写任何文件
#      （在只读根文件系统上同样可用）。
#    · 可选依赖（缺了只跳过对应检查，不影响其它项）：
#        nvidia-smi（NVIDIA 显存）、vulkaninfo/vulkan-tools（Vulkan 枚举）、lspci/pciutils（拓扑）、
#        python3（解析 Steam shortcuts.vdf 的**首选**实现；缺失时改用内置 coreutils 解析器，
#                 后者需要 grep 支持 -b 与 od —— GNU 工具链都满足；Alpine 等 BusyBox-only
#                 环境会明确提示"请安装 python3"，不会静默失败）、
#        timeout（coreutils，给 vulkaninfo 加超时）、steam / flatpak / xdg-open（仅 -l 启动用）。
#    · 平台范围：NVIDIA 与 AMD/amdgpu 驱动检查都支持；Intel 平台仍做内存与 Vulkan 检查，
#      驱动专属项会明确提示"未检测到"。
#    · 调试用环境变量：OS_RELEASE_FILE（默认 /etc/os-release）、FORCE_GPU=auto|nvidia|amd
#      （强制走某个驱动分支，便于在容器/特殊模块名环境下验证）。
# ============================================================================
set -uo pipefail

# ----------------------------------------------------------------- 默认值
# Steam 安装位置：支持原生 Steam、SteamOS/Steam Deck 默认路径、以及 Flatpak 版 Steam
#   · STEAM_DIR 指定后只扫这一个；否则自动探测下面所有候选（多装可共存，全部扫）
#   · STEAM_USERDATA 可选：指定 userdata 数字目录（多账号时避免扫错）
STEAM_DIR="${STEAM_DIR:-}"
STEAM_USERDATA="${STEAM_USERDATA:-}"
STEAM_ROOTS=()                 # 探测到的所有 Steam 根目录（去重、真实路径）
STEAM_KEYS=()                  # 去重用（userdata 的真实路径）
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
FORCE_GPU="${FORCE_GPU:-auto}"      # auto（默认）| nvidia | amd：强制走某个驱动分支（调试/特殊环境）
IS_STEAMOS=0

VRAM_WARN_MIB="${VRAM_WARN_MIB:-2000}"     # 空闲时显存占用超过此值 → 疑似泄漏
VRAM_WARN_PCT="${VRAM_WARN_PCT:-80}"       # 显存占用超过此百分比 → 警告
RAM_MIN_MIB="${RAM_MIN_MIB:-2048}"         # 可用内存低于此值 → 警告
SWAP_WARN_MIB="${SWAP_WARN_MIB:-4096}"     # 交换已用超过此值 → 警告
JOURNAL_ARGS="${JOURNAL_ARGS:--b -k}"      # 默认只看本次开机
XID_SERIOUS="${XID_SERIOUS:-48 56 62 74 79 94 95 109 119 120}"

# NVIDIA：致命 = GPU channel / GSP 分配失败（“D3D12 设备建不出来” 的直接原因）
NVRM_CRIT_RE='kchangrpapi|GspRmAlloc'
# NVIDIA 警告：分配真的失败 / VA 空间坏掉。不能只匹配 NV_ERR_NO_MEMORY：单独一条
#       “大页失败后改用默认页重试” 是良性瞬时事件（本机实测出现过），会误报。
NVRM_WARN_RE='dmaAllocMapping|gvaspaceMapping|gpu_vaspace[.]c|virt_mem_allocator|system_mem[.]c|nv_gpu_ops[.]c|pmaAllocatePages|ctxBufPoolReserve|nvAssert(Ok)?Failed.*[Oo]ut of memory'

# AMD/amdgpu（SteamOS、Steam Deck、AMD 显卡）：致命 = GPU 复位 / MES 无响应；
# 警告 = ring 超时、页错误（可能是软恢复，也可能是黑屏前兆）
AMD_CRIT_RE='amdgpu.*(GPU reset|MES.*(failed|timeout)|failed to respond to msg|GPU hang|hardware error|Fence fallback timer expired|flushed .*timeout|Resetting .*ring)'
AMD_WARN_RE='amdgpu.*(ring .*timeout|PROTECTION_FAULT|no-retry page fault|page fault|soft recovered|SMU.*(failed|timeout)|PSP.*(failed|timeout)|ip block.*timeout)'

CONF_FILE="${GPU_PREFLIGHT_CONF:-$HOME/.config/gpu-preflight.conf}"
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

# 探测所有 Steam 根目录（去重；.steam/steam 常是指向 .local/share/Steam 的软链）
#
# 说明：非 Steam 快捷方式（"右键 → 添加到 Steam"）只存在于
#   <Steam 根>/userdata/<账号 id>/config/shortcuts.vdf
# 所以这里只要发现 userdata 或 steamapps 任一存在就当作 Steam 根（新装/只放库的目录
# 可能还没有 steamapps，但 shortcuts.vdf 已经存在）。
#
# 用 sudo 运行时 $HOME 会变成 /root，导致找不到 Steam；这里优先用 SUDO_USER 的家目录，
# 并兜底扫 /home/*（只有 root 读得到别人的家目录）。
steam_homes() {
    local h
    if [ -n "${STEAM_USER_HOME:-}" ]; then printf '%s\n' "$STEAM_USER_HOME"
    elif [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
        h="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: '{print $6}')"
        [ -n "$h" ] && printf '%s\n' "$h" || printf '%s\n' "$HOME"
    else
        printf '%s\n' "$HOME"
    fi
    # root 兜底：别人的家目录（/home/*），便于 sudo 场景
    if [ "$(id -u)" = 0 ]; then
        for h in /home/*; do [ -d "$h" ] && printf '%s\n' "$h"; done
    fi
}

detect_steam_roots() {
    local h cand real key seen
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        for cand in "$STEAM_DIR" \
                    "$h/.local/share/Steam" \
                    "$h/.steam/steam" \
                    "$h/.steam/root" \
                    "$h/.steam/debian-installation" \
                    "$h/.var/app/com.valvesoftware.Steam/data/Steam" \
                    "$h/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
            [ -n "$cand" ] || continue
            [ -d "$cand/userdata" ] || [ -d "$cand/steamapps" ] || continue
            real="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
            # 去重键用 userdata 的真实路径：~/.steam/steam 常是真实目录 + 内部软链，
            # 只比较目录本身会把同一份 userdata 扫两遍
            key="$(readlink -f "$cand/userdata" 2>/dev/null || printf '%s' "$real")"
            for seen in ${STEAM_KEYS[@]+"${STEAM_KEYS[@]}"}; do
                [ "$seen" = "$key" ] && continue 2
            done
            STEAM_KEYS+=("$key")
            STEAM_ROOTS+=("$real")
        done
    done <<<"$(steam_homes)"
}

# 给根目录打标签（输出用）
steam_root_kind() {
    case "$1" in
        */.var/app/com.valvesoftware.Steam/*) printf 'Flatpak Steam' ;;
        *) [ "$IS_STEAMOS" = 1 ] && printf 'SteamOS 内置 Steam' || printf '原生 Steam' ;;
    esac
}

# 列出某个根目录下所有账号的 shortcuts.vdf（不是只取第一个！）
# 一个 Steam 根下可能有 userdata/0 与 userdata/<数字 SteamID> 多个账号，
# 只取第一个会漏掉真正有快捷方式的那个账号。
vdfs_of_root() {
    local root="$1" d
    if [ -n "$STEAM_USERDATA" ]; then
        d="$root/userdata/$STEAM_USERDATA/config/shortcuts.vdf"
        [ -r "$d" ] && printf '%s\n' "$d"
        return 0
    fi
    for d in "$root"/userdata/*/config/shortcuts.vdf; do
        [ -r "$d" ] && printf '%s\n' "$d"
    done
    return 0
}

# 纯 coreutils 的 shortcuts.vdf 解析（python3 缺失时用；BusyBox 工具也能跑）
#
# 二进制 VDF 的结构：每个键以类型字节开头（\x01=字符串 \x02=int32），键名以 \0 结尾；
# 字符串键后面紧跟以 \0 结尾的值；int32 键后面是 4 字节小端整数。
# 这里不用 python3 的做法：
#   · appid ：grep -abo 找到 "appid" 的字节偏移，再从 偏移+6 读 4 字节小端整数
#   · 字符串：同样找键名偏移，校验前一个字节是 0x01、后一个字节是 0x00，
#             然后用 dd 取值、tr 把 \0 换成换行、sed 取第一行
# UTF-8 全程按字节传递，不依赖 locale。
bs_vdf_field_offsets() {
    local vdf="$1" key="$2" off prev next
    grep -abo -- "$key" "$vdf" 2>/dev/null | while IFS=: read -r off _; do
        prev="$(od -An -tu1 -j $((off - 1)) -N 1 "$vdf" 2>/dev/null | tr -d ' ')"
        next="$(od -An -tu1 -j $((off + ${#key})) -N 1 "$vdf" 2>/dev/null | tr -d ' ')"
        [ "$prev" = "1" ] && [ "$next" = "0" ] && printf '%s\n' "$off"
    done
}

bs_vdf_strings() {
    local vdf="$1" key="$2" off
    bs_vdf_field_offsets "$vdf" "$key" | while IFS= read -r off; do
        dd if="$vdf" bs=1 skip=$((off + ${#key} + 1)) count=4096 2>/dev/null \
            | tr '\0' '\n' | sed -n 1p
    done
}

bs_vdf_appids() {
    local vdf="$1" off
    grep -abo -- 'appid' "$vdf" 2>/dev/null | while IFS=: read -r off _; do
        dd if="$vdf" bs=1 skip=$((off + 6)) count=4 2>/dev/null | od -An -tu4 | tr -d ' '
    done
}

# 纯 coreutils 解析器是否可用：需要 grep 支持 -b（字节偏移）与 od
#   · SteamOS / Arch / Debian / Fedora 等 GNU 工具链：可用 ✓
#   · Alpine 等 BusyBox-only 环境：grep 没有 -b，od 也可能没有 → 明确提示装 python3
BS_PARSER_OK=""
bs_parser_ready() {
    [ -n "$BS_PARSER_OK" ] && { [ "$BS_PARSER_OK" = 1 ]; return; }
    BS_PARSER_OK=0
    if have grep && have od && have dd; then
        local probe="${TMPDIR:-/tmp}/gpu-preflight.probe.$$"
        printf 'x' > "$probe" 2>/dev/null
        if grep -abo x "$probe" >/dev/null 2>&1; then BS_PARSER_OK=1; fi
        rm -f "$probe" 2>/dev/null
    fi
    [ "$BS_PARSER_OK" = 1 ]
}

list_shortcuts_bs() {
    local vdf="$1" tmp
    if ! bs_parser_ready; then
        warn "无 python3，且本机 grep 不支持 -b 或缺 od → 无法解析 shortcuts.vdf" >&2
        warn "请安装 python3（推荐），或改用 GNU grep + GNU coreutils（od）" >&2
        return 1
    fi
    # 用带模板的 mktemp（BusyBox 的 mktemp 要求模板），失败再退回 mkdir
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/gpu-preflight.vdf.XXXXXX" 2>/dev/null)" || tmp=""
    if [ -z "$tmp" ]; then
        tmp="${TMPDIR:-/tmp}/gpu-preflight.vdf.$$"
        mkdir -p "$tmp" 2>/dev/null || return 1
    fi
    bs_vdf_appids "$vdf"                                     > "$tmp/appid"
    bs_vdf_strings "$vdf" AppName                            > "$tmp/name"
    bs_vdf_strings "$vdf" Exe                                > "$tmp/exe"
    bs_vdf_strings "$vdf" StartDir                           > "$tmp/start"
    bs_vdf_strings "$vdf" LaunchOptions                      > "$tmp/opts"

    # 用 paste 按行拼起来；某列比别的短时 paste 会补空，正好容错
    paste -d '\t' "$tmp/appid" "$tmp/name" "$tmp/exe" "$tmp/start" "$tmp/opts" 2>/dev/null
    rm -rf "$tmp" 2>/dev/null
}

# ----------------------------------------------------------------- 运行状态
CRITICAL=0
WARNINGS=0
GAME_MATCH=""
ALL_GAMES=0
LIST_GAMES=0
DO_LAUNCH=0
ASSUME_YES=0
QUIET=0
VERBOSE=0
SKIP_VULKAN=0
DEBUG_STEAM=0
LAUNCH_APPID=""
LAUNCH_ROOT=""

# ----------------------------------------------------------------- 输出
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYA=$'\e[36m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
    C_RED=; C_GRN=; C_YEL=; C_CYA=; C_DIM=; C_RST=
fi

sec()  { [ "$QUIET" = 1 ] && return 0; printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_RST"; }
ok()   { [ "$QUIET" = 1 ] && return 0; printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$1"; }
info() { [ "$QUIET" = 1 ] && return 0; printf '  %s·%s %s\n' "$C_CYA" "$C_RST" "$1"; }
note() { [ "$QUIET" = 1 ] && return 0; printf '    %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }
vnote(){ [ "$QUIET" = 1 ] && return 0; [ "$VERBOSE" = 1 ] || return 0
         printf '    %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$1"; }
bad()  { CRITICAL=1; printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$1"; }

usage() {
    awk 'NR > 1 && /^# =====/ { if (++n == 2) exit; next }
         NR > 1 && /^#/ { sub(/^# ?/, ""); print }' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --game)        shift; GAME_MATCH="${1:-}" ;;
        --game=*)      GAME_MATCH="${1#*=}" ;;
        --all-games)   ALL_GAMES=1 ;;
        --list-games)  LIST_GAMES=1 ;;
        -l|--launch)   DO_LAUNCH=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        -q|--quiet)    QUIET=1 ;;
        -v|--verbose)  VERBOSE=1 ;;
        --no-vulkan)   SKIP_VULKAN=1 ;;
        --debug-steam) DEBUG_STEAM=1 ;;
        --no-color)    C_RED=; C_GRN=; C_YEL=; C_CYA=; C_DIM=; C_RST= ;;
        -h|--help)     usage ;;
        *) echo "未知参数: $1（-h 看帮助）" >&2; exit 64 ;;
    esac
    shift
done

have() { command -v "$1" >/dev/null 2>&1; }

# 版本号只取前两段，便于比较 615.71.09 与 615.71.9 这种写法差异。
# 注意：不能用 awk -F'[^0-9]+' 取 $2/$3 —— BusyBox awk 不会为行首分隔符产生空字段，
#       会算出错误结果；用 match()+substr 在 gawk / mawk / BusyBox awk 下行为一致。
ver2() { printf '%s' "${1:-}" | awk '{ if (match($0, /[0-9]+\.[0-9]+/)) print substr($0, RSTART, RLENGTH) }' 2>/dev/null; }

xid_is_serious() {
    local c
    for c in $XID_SERIOUS; do [ "$c" = "$1" ] && return 0; done
    return 1
}

# ============================================================ 1. 环境信息
check_env() {
    sec "1. 环境与显卡拓扑"

    local distro kernel
    distro="$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' "$OS_RELEASE_FILE" 2>/dev/null)"
    kernel="$(uname -r)"
    note "系统: ${distro:-未知}　内核: $kernel"

    # SteamOS / Steam Deck 特有提示
    if [ "$IS_STEAMOS" = 1 ]; then
        info "检测到 SteamOS / Steam Deck（不可变系统）"
        note "驱动与组件来自系统镜像：不要手动改 /usr（改动会在系统更新后消失，还可能影响开机）"
        note "要更新驱动/Proton：走 设置 → 系统更新（可切 Beta 通道），或在 Steam 里改 Proton 版本"
        if have steamos-readonly; then
            vnote "steamos-readonly: $(steamos-readonly status 2>/dev/null)"
        fi
    fi

    if have lspci; then
        while IFS= read -r g; do vnote "GPU: $g"; done \
            < <(lspci 2>/dev/null | grep -iE 'vga|3d|display' | cut -c1-120)
    fi

    if [ -r /proc/driver/nvidia/version ]; then
        note "NVIDIA 内核模块: $(head -1 /proc/driver/nvidia/version | sed 's/  */ /g')"
    fi
    if [ -d /sys/module/amdgpu ]; then
        vnote "amdgpu 模块已加载"
    fi
    if [ -r /sys/module/nvidia_drm/parameters/modeset ]; then
        vnote "nvidia_drm: modeset=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null) fbdev=$(cat /sys/module/nvidia_drm/parameters/fbdev 2>/dev/null)"
    fi

    # 谁在驱动显示器（混合显卡排查的关键信息）
    local card status bootvga
    for card in /sys/class/drm/card[0-9]*; do
        [ -e "$card/device/uevent" ] || continue
        local drv pci conns=""
        drv="$(awk -F= '/^DRIVER=/{print $2}' "$card/device/uevent" 2>/dev/null)"
        pci="$(awk -F= '/^PCI_ID=/{print $2}' "$card/device/uevent" 2>/dev/null)"
        bootvga="$(cat "$card/device/boot_vga" 2>/dev/null)"
        for status in "$card"-*/status; do
            [ -r "$status" ] || continue
            [ "$(cat "$status" 2>/dev/null)" = "connected" ] && \
                conns="$conns $(basename "$(dirname "$status")")"
        done
        vnote "  $(basename "$card"): driver=${drv:-?} pci=$pci boot_vga=${bootvga:-?} 已连接输出:${conns:- 无}"
    done

    # 混合显卡提示（lspci 可能没装，缺了就不提示）
    local n_gpu=0
    if have lspci; then
        n_gpu="$(lspci 2>/dev/null | grep -icE 'vga|3d|display')"
    fi
    if [ "${n_gpu:-0}" -gt 1 ]; then
        info "检测到多显卡（混合显卡）。D3D12/Proton 默认优先独显；如要强制指定，"
        note "可用 DXVK_FILTER_DEVICE_NAME / VKD3D_FILTER_DEVICE_NAME（注意后者在部分驱动上不稳定）"
    fi
}

# ============================================================ 2. 驱动内核态
# 统计并抽取样例行：结果放全局 SCAN_CRIT / SCAN_WARN / SCAN_FIRST / SCAN_SAMPLES
# $1=致命正则  $2=警告正则  （依赖 check_driver 里准备好的 $DUMP / $KLOG_SOURCE）
scan_set() {
    local re="$1|$2"
    SCAN_CRIT="$(printf '%s\n' "$DUMP" | grep -cE "$1" || true)"
    SCAN_WARN="$(printf '%s\n' "$DUMP" | grep -cE "$2" || true)"
    # 用 awk 而不是 grep|head：管道被 head 提前关闭会刷“断开的管道”警告；
    # awk 也不提前 exit（否则写大段日志的 printf 会报 EPIPE）。
    # 时间戳格式 journalctl 与 dmesg 不同，按来源分别取。
    SCAN_FIRST="$(printf '%s\n' "$DUMP" | awk -v re="$re" -v src="$KLOG_SOURCE" \
                  '$0 ~ re && !got { if (src == "dmesg") print $1; else print $1, $2, $3; got = 1 }')"
    SCAN_SAMPLES="$(printf '%s\n' "$DUMP" | awk -v re="$re" -v src="$KLOG_SOURCE" \
                    '$0 ~ re && n < 2 { sub(/.*kernel: /, ""); if (src == "dmesg") sub(/^\[[^]]*\][ ]*/, "");
                                        print substr($0, 1, 110); n++ }')"
}

show_samples() {
    printf '%s\n' "${SCAN_SAMPLES:-}" | while IFS= read -r l; do [ -n "$l" ] && note "证据: $l"; done
}

check_driver() {
    sec "2. 显卡驱动内核态"

    local has_nv=0 has_amd=0
    { [ -r /proc/driver/nvidia/version ] || have nvidia-smi; } && has_nv=1
    { [ -d /sys/module/amdgpu ] || grep -q '^amdgpu ' /proc/modules 2>/dev/null; } && has_amd=1
    case "${FORCE_GPU:-auto}" in
        nvidia) has_nv=1; has_amd=0 ;;
        amd)    has_nv=0; has_amd=1 ;;
    esac

    if [ "$has_nv" = 0 ] && [ "$has_amd" = 0 ]; then
        info "未检测到 NVIDIA / AMD 独立驱动（本检查项针对这两类；Intel 平台可忽略）"
        return
    fi

    # 取内核日志：优先 journald（支持 -b / -b -1 看上一次开机），
    # 没有 systemd（Void/Artix/Alpine…）或 journal 未持久化时退回 dmesg。
    # 注意：赋值必须写在调用方（函数里的全局赋值放进 $() 会丢，因为那是子 shell）。
    DUMP="" KLOG_SOURCE=""
    if have journalctl; then
        DUMP="$(journalctl $JOURNAL_ARGS --no-pager 2>/dev/null || true)"
        [ -n "$DUMP" ] && KLOG_SOURCE="journalctl $JOURNAL_ARGS"
    fi
    if [ -z "$DUMP" ] && have dmesg; then
        DUMP="$(dmesg 2>/dev/null || true)"
        [ -n "$DUMP" ] && KLOG_SOURCE="dmesg"
    fi
    if [ -z "$DUMP" ]; then
        warn "无法读取内核日志 → 这项检查没做（不代表有问题，只是无法判定）"
        note "常见原因：非 systemd 发行版且非 root（kernel.dmesg_restrict=1），或 journal 未持久化"
        note "可试：sudo dmesg | grep -E 'NVRM|amdgpu'　或　把 kernel.dmesg_restrict 设为 0"
        return
    fi
    note "内核日志来源: $KLOG_SOURCE"

    # ---------------- NVIDIA ----------------
    if [ "$has_nv" = 1 ]; then
        vnote "检查 NVIDIA（NVRM / Xid）"
        scan_set "$NVRM_CRIT_RE" "$NVRM_WARN_RE"
        note "NVIDIA：channel/GSP 分配失败 ${SCAN_CRIT} 条　内存/VA 空间异常 ${SCAN_WARN} 条"
        if [ "${SCAN_CRIT:-0}" -gt 0 ]; then
            bad "NVIDIA 驱动已损坏：GPU channel / GSP 分配失败 ${SCAN_CRIT} 条（最早 ${SCAN_FIRST}）"
            show_samples
            note "后果：vkd3d-proton 建不出 D3D12 设备 → D3D12 游戏黑屏（有声音）"
            note "而且每启动一次都会往坏掉的地址空间再叠一批映射，只会更糟 → 先重启"
        elif [ "${SCAN_WARN:-0}" -gt 0 ]; then
            warn "NVIDIA 驱动出现内存/VA 空间异常 ${SCAN_WARN} 条（最早 ${SCAN_FIRST}）"
            show_samples
            note "还没到致命那一步，但继续跑很可能恶化；建议先重启再玩"
        else
            ok "NVIDIA 驱动内核态干净：没有 NVRM 分配/映射错误"
        fi

        # Xid（NVIDIA GPU 故障码）
        local xid_raw codes
        xid_raw="$(printf '%s\n' "$DUMP" | grep -oE 'Xid[^)]*\): [0-9]+' | awk -F': ' '{print $NF}')"
        if [ -n "$xid_raw" ]; then
            codes="$(printf '%s\n' "$xid_raw" | sort -n | uniq -c | awk '{printf "%s×%s ", $2, $1}')"
            local serious_hit=""
            while IFS= read -r c; do
                [ -n "$c" ] && xid_is_serious "$c" && serious_hit="$serious_hit $c"
            done <<<"$xid_raw"
            if [ -n "$serious_hit" ]; then
                warn "本次出现过严重 GPU 故障码 Xid:$(printf '%s' "$serious_hit" | tr ' ' '\n' | sort -nu | tr '\n' ' ')"
                note "全部 Xid 统计: $codes"
                note "建议重启后再玩；若反复出现，多半是驱动/电源管理问题（查 dmesg 与 NVIDIA 论坛）"
            else
                note "Xid 记录: $codes（非严重码，通常是应用侧问题）"
            fi
        fi
    fi

    # ---------------- AMD / amdgpu（SteamOS、Steam Deck、AMD 独显/核显）----------------
    if [ "$has_amd" = 1 ]; then
        vnote "检查 AMD（amdgpu）"
        scan_set "$AMD_CRIT_RE" "$AMD_WARN_RE"
        note "AMD：GPU reset / MES 失败 ${SCAN_CRIT} 条　ring 超时/页错误 ${SCAN_WARN} 条"
        if [ "${SCAN_CRIT:-0}" -gt 0 ]; then
            bad "amdgpu 出现 GPU 复位 / MES 无响应 ${SCAN_CRIT} 条（最早 ${SCAN_FIRST}）"
            show_samples
            note "GPU 一旦复位过，本次开机内经常继续出错（黑屏/掉驱动）→ 建议先重启再玩"
            note "SteamOS/Deck 上这类问题多与驱动版本或超频/功耗设置有关；重启后先别加载超频工具"
        elif [ "${SCAN_WARN:-0}" -gt 0 ]; then
            warn "amdgpu 出现 ring 超时 / 页错误 ${SCAN_WARN} 条（最早 ${SCAN_FIRST}）"
            show_samples
            note "有“soft recovered”多为软恢复，但仍可能伴随卡顿/黑屏；若反复出现建议重启"
        else
            ok "amdgpu 内核态干净：没有 GPU reset / ring 超时 / 页错误"
        fi
    fi
}

# ============================================================ 3. 显存/内存
check_memory() {
    sec "3. 显存 / 内存 / 交换"

    # ---- 显存 & 驱动对答 ----
    if have nvidia-smi; then
        local out
        out="$(nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null)"
        if [ -z "$out" ]; then
            bad "nvidia-smi 不可用：驱动未加载，或用户态与内核模块版本不一致"
            [ -r /proc/driver/nvidia/version ] && note "内核模块版本见上方“环境”一节；修复后需重启"
        else
            local n=0
            while IFS= read -r line; do
                n=$((n + 1))
                local gname gdrv used total pct
                gname="$(printf '%s' "$line" | awk -F', ' '{print $1}')"
                gdrv="$(printf '%s' "$line" | awk -F', ' '{print $2}')"
                used="$(printf '%s' "$line" | awk -F', ' '{print $3}')"
                total="$(printf '%s' "$line" | awk -F', ' '{print $4}')"
                if [ -z "${total:-}" ] || [ "${total:-0}" -eq 0 ] 2>/dev/null; then
                    continue
                fi
                pct=$((used * 100 / total))
                note "GPU$n $gname 驱动 $gdrv　显存 ${used}/${total} MiB（${pct}%）"
                if [ "$used" -ge "$VRAM_WARN_MIB" ] || [ "$pct" -ge "$VRAM_WARN_PCT" ]; then
                    warn "显存占用偏高（阈值 ${VRAM_WARN_MIB} MiB / ${VRAM_WARN_PCT}%）"
                    note "空闲时过高通常是有程序/上一局游戏没释放；显存耗尽正是最初把驱动搞坏的诱因"
                else
                    ok "显存占用正常"
                fi
            done <<<"$out"

            # 内核模块 vs 用户态版本一致性
            local kver uver
            # 版本号位置在不同驱动/架构下写法不一（老版无 "for x86_64"），取第一个形如 x.y 的字段最稳
            kver="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit }}' /proc/driver/nvidia/version 2>/dev/null)"
            uver="$(printf '%s\n' "$out" | head -1 | awk -F', ' '{print $2}')"
            if [ -n "$kver" ] && [ -n "$uver" ]; then
                vnote "内核模块 $kver / 用户态(nvidia-smi) $uver"
                if [ "$(ver2 "$kver")" != "$(ver2 "$uver")" ]; then
                    warn "内核模块与用户态驱动版本不一致（$kver vs $uver）"
                    note "这会让所有 GPU 应用异常；需要重装/统一 nvidia 包后重启"
                fi
            fi
        fi
    else
        note "没有 nvidia-smi（非 NVIDIA 平台？），跳过显存检查"
    fi

    # ---- 内存 / 交换 ----
    local total avail stotal sfree suse
    total=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)
    stotal=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo)
    sfree=$(awk '/^SwapFree:/{printf "%d", $2/1024}' /proc/meminfo)
    suse=$((stotal - sfree))

    note "内存: 已用 $((total - avail)) MiB / 共 ${total} MiB，可用 ${avail} MiB"
    note "交换: 已用 ${suse} MiB / 共 ${stotal} MiB"
    if [ "$avail" -lt "$RAM_MIN_MIB" ]; then
        warn "可用内存过低（< ${RAM_MIN_MIB} MiB）"
        note "内存紧张时驱动的内核态分配最容易失败；关掉浏览器/聊天软件再启动"
    else
        ok "内存充足"
    fi

    # SteamOS/Steam Deck 默认用 zram（压缩内存，不是磁盘 swap）：占用高是常态，
    # 单看它容易误报，所以结合可用内存一起判断；真实 swap 仍按绝对阈值。
    local swap_pct=0 swap_is_zram=0
    [ "$stotal" -gt 0 ] && swap_pct=$((suse * 100 / stotal))
    ls /sys/block/zram* >/dev/null 2>&1 && swap_is_zram=1
    if [ "$swap_is_zram" = 1 ]; then
        if [ "$suse" -gt "$SWAP_WARN_MIB" ] && [ "$avail" -lt "$RAM_MIN_MIB" ]; then
            warn "zram 已用 ${suse} MiB 且可用内存只剩 ${avail} MiB → 内存压力大，建议先关程序/重启"
        else
            ok "zram（压缩交换）已用 ${suse} MiB（${swap_pct}%），配合可用内存看属正常"
        fi
    elif [ "$suse" -gt "$SWAP_WARN_MIB" ] || [ "$swap_pct" -ge 80 ]; then
        warn "交换占用偏高：已用 ${suse} MiB（${swap_pct}%）"
    else
        ok "交换占用正常（已用 ${suse} MiB，${swap_pct}%）"
    fi
}

# ============================================================ 4. Vulkan
check_vulkan() {
    sec "4. Vulkan 设备可见性"

    if [ "$SKIP_VULKAN" = 1 ]; then
        note "已用 --no-vulkan 跳过"
        return
    fi
    if ! have vulkaninfo; then
        note "没装 vulkaninfo（vulkan-tools），跳过"
        return
    fi

    local out tmo=""
    have timeout && tmo="timeout 25"          # timeout 是 coreutils，缺了也能跑

    # 先试 --summary（vulkan-tools 新版本支持）；老版本没有这个参数就退回完整输出，
    # 两者都包含 deviceName / driverName / driverInfo，可以用同一套解析。
    out="$($tmo vulkaninfo --summary 2>/dev/null || true)"
    [ -z "$out" ] && out="$($tmo vulkaninfo 2>/dev/null || true)"
    if [ -z "$out" ]; then
        warn "vulkaninfo 执行失败/无输出：Vulkan 加载器或 ICD 有问题，任何 D3D→Vulkan 转译都会挂"
        note "排查：确认发行版的 Vulkan ICD 加载器与显卡驱动包已装、/usr/share/vulkan/icd.d 有对应 json、"
        note "      设备节点可访问（/dev/dri、/dev/nvidia*），也可看 dmesg 与 vulkaninfo 的报错"
        return
    fi

    # 每个 GPU 一段：deviceName / driverName / driverInfo
    local rows
    rows="$(printf '%s\n' "$out" | awk '
        /deviceName[ \t]*=/ { sub(/.*= /, ""); name = $0 }
        /driverName[ \t]*=/ { sub(/.*= /, ""); drv = $0 }
        /driverInfo[ \t]*=/ { sub(/.*= /, ""); inf = $0;
            if (name != "") { printf "%s | %s | %s\n", name, drv, inf; name = ""; drv = ""; inf = "" } }
    ')"
    if [ -z "$rows" ]; then
        warn "vulkaninfo 没列出任何设备"
        return
    fi

    local count=0 nvidia_seen=0
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        count=$((count + 1))
        info "Vulkan 设备$count: $r"
        printf '%s' "$r" | grep -qi 'nvidia' && nvidia_seen=1
    done <<<"$rows"
    ok "Vulkan 枚举到 $count 个设备"

    if [ -r /proc/driver/nvidia/version ] && [ "$nvidia_seen" = 0 ]; then
        warn "系统里有 NVIDIA 驱动，但 Vulkan 里看不到 NVIDIA 设备"
        note "D3D12/DXVK 都会失败；检查 nvidia_icd.json、/dev/nvidia*、以及是否被环境变量过滤"
    fi
}

# ============================================================ 5. Steam 游戏
# 读某个 shortcuts.vdf，输出每个快捷方式：
#   appid \t 名称 \t Exe \t 启动目录 \t 启动项
list_shortcuts() {
    local vdf="$1"
    [ -n "$vdf" ] && [ -r "$vdf" ] || return 0
    # 有 python3 就用 python3（更快更好读）；没有就用内置的 coreutils 解析器
    # （SteamOS / 极简发行版上 python3 可能不存在，这样也不会漏掉非 Steam 快捷方式）
    if ! have python3; then
        list_shortcuts_bs "$vdf"
        return 0
    fi
    python3 - "$vdf" <<'PY' 2>/dev/null
import re, sys
try:
    d = open(sys.argv[1], 'rb').read()
except OSError:
    sys.exit(0)
items = []
for m in re.finditer(rb'[\x01\x02]([A-Za-z_]+)\x00', d):
    kind, key = d[m.start()], m.group(1).decode('ascii', 'replace')
    if kind == 0x02 and key == 'appid':
        items.append((key, str(int.from_bytes(d[m.end():m.end() + 4], 'little'))))
    elif kind == 0x01 and key in ('AppName', 'Exe', 'StartDir', 'LaunchOptions'):
        end = d.index(b'\x00', m.end())
        items.append((key, d[m.end():end].decode('utf-8', 'replace')))
groups, cur = [], None
for k, v in items:
    if k == 'appid':
        cur = {'appid': v}
        groups.append(cur)
    elif cur is not None:
        cur[k] = v
for g in groups:
    print('\t'.join([g.get('appid', ''), g.get('AppName', ''), g.get('Exe', ''),
                     g.get('StartDir', ''), g.get('LaunchOptions', '').replace('\t', ' ')]))
PY
}

exe_dir_of() {  # 去掉引号，取所在目录
    local e="${1//\"/}"
    [ -n "$e" ] || return 1
    printf '%s' "$(dirname "$e")"
}

# 判断这个游戏目录是不是 Doorstop 注入（BepInEx 等）
is_doorstop_dir() {
    local dir="$1"
    [ -f "$dir/winhttp.dll" ] || return 1
    grep -qai 'doorstop' "$dir/winhttp.dll" 2>/dev/null
}

# 启动项 / 前缀注册表里是否已经给了 winhttp 原生优先（native 排在最前）
# $1=Steam 根目录  $2=启动项  $3=appid
has_winhttp_override() {
    local root="$1" opts="$2" appid="$3" reg
    printf '%s' "$opts" | grep -qE 'WINEDLLOVERRIDES=.*winhttp=n' && return 0
    reg="$root/steamapps/compatdata/$appid/pfx/user.reg"
    [ -r "$reg" ] && grep -qE '"winhttp"="n' "$reg" && return 0
    return 1
}

# $1=Steam 根目录  $2=appid
check_prefix() {
    local root="$1" appid="$2"
    local cdir="$root/steamapps/compatdata/$appid"
    if [ -z "$appid" ] || [ ! -d "$cdir" ]; then
        warn "还没有 Proton 前缀（compatdata/${appid:-?} 不存在）：先用 Proton 跑一次游戏再看"
        return
    fi
    local proton="" s32="$cdir/pfx/drive_c/windows/system32"
    [ -r "$cdir/version" ] && proton="$(head -1 "$cdir/version" 2>/dev/null)"
    info "Proton: ${proton:-未知}（compatdata/$appid）"

    if [ -f "$s32/d3d12core.dll" ]; then
        ok "前缀里有 vkd3d-proton（d3d12core.dll）"
    else
        warn "前缀里没有 d3d12core.dll → 这个前演奏不出 D3D12（DX12 游戏会失败）"
        note "用当前 Proton 跑一次游戏让它补齐，或换 Proton/清前缀重来"
    fi

    if [ -f "$s32/dxgi.dll" ]; then
        local sz
        sz=$(wc -c < "$s32/dxgi.dll" 2>/dev/null || echo 0)
        if [ "$sz" -gt 1000000 ]; then
            vnote "DXVK: dxgi.dll $((sz / 1024)) KiB"
        else
            warn "前缀里的 dxgi.dll 很小（$((sz / 1024)) KiB），可能不是 DXVK（D3D9/10/11 性能与兼容会受影响）"
        fi
    fi
}

check_one_game() {
    local root="$1" appid="$2" name="$3" exe="$4" opts="$5"
    local dir; dir="$(exe_dir_of "$exe" 2>/dev/null || true)"

    info "游戏: ${name:-?}（appid ${appid:-?}）"
    vnote "Steam: $root（$(steam_root_kind "$root")）"
    vnote "Exe: $exe"
    note "启动项: ${opts:-<空>}"

    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        warn "游戏目录不存在: ${dir:-?}"
        return
    fi

    # --- Doorstop / BepInEx 注入链 ---
    if is_doorstop_dir "$dir"; then
        note "检测到 Doorstop 注入器（BepInEx/汉化/Mod）: $dir/winhttp.dll"
        if [ -f "$dir/doorstop_config.ini" ]; then
            if grep -qE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' "$dir/doorstop_config.ini"; then
                vnote "doorstop_config.ini: enabled = true"
            else
                warn "doorstop_config.ini 里 enabled 不是 true → 注入被关掉了"
            fi
        else
            warn "缺少 doorstop_config.ini → Doorstop 无法启动"
        fi
        if has_winhttp_override "$root" "$opts" "$appid"; then
            ok "已给 winhttp 原生优先（Proton 下注入器能加载）"
        else
            warn "启动项没给 winhttp 原生优先 → Proton 会用内置 winhttp，注入器不执行，汉化/Mod 失效"
            note "在该游戏 属性 → 启动选项 里加：WINEDLLOVERRIDES=winhttp=n,b %command% <原有参数>"
        fi
    else
        vnote "未检测到 Doorstop 注入器（无需 winhttp 覆盖）"
    fi

    # --- 自带 Agility SDK（说明这个游戏必须走 D3D12）---
    if [ -f "$dir/D3D12/D3D12Core.dll" ]; then
        note "游戏自带 Agility SDK（D3D12/D3D12Core.dll）→ 必须走 D3D12"
        note "所以上面的“驱动内核态”与 vkd3d-proton 是否可用，直接决定它能否出画面"
    fi

    check_prefix "$root" "$appid"
}

check_games() {
    [ "$ALL_GAMES" = 1 ] || [ "$LIST_GAMES" = 1 ] || [ -n "$GAME_MATCH" ] || return 0
    if [ "${STEAM_ROOTS[*]:-}" = "" ]; then
        warn "没有找到任何 Steam 安装目录"
        note "已探测：\$HOME/.local/share/Steam、\$HOME/.steam/{steam,root,debian-installation}、"
        note "        Flatpak 的 \$HOME/.var/app/com.valvesoftware.Steam/{data/Steam,.local/share/Steam}"
        note "可用 STEAM_DIR=/路径 手动指定；用 sudo 跑会按 SUDO_USER 的家目录找；"
        note "--debug-steam 可看详细探测过程"
        return
    fi

    sec "5. Steam 快捷方式"
    if ! have python3; then
        info "没有 python3 → 使用内置 coreutils 解析器读 shortcuts.vdf（功能相同，速度稍慢）"
    fi

    local root vdf acct appid name exe startdir opts n=0 ds_total=0 ds_bad=0 roots_used=0 vdfs_seen=0
    for root in ${STEAM_ROOTS[@]+"${STEAM_ROOTS[@]}"}; do
        note "Steam 根目录: $root（$(steam_root_kind "$root")）"

        local any_vdf=0
        while IFS= read -r vdf; do
            [ -n "$vdf" ] || continue
            any_vdf=1
            vdfs_seen=$((vdfs_seen + 1))
            acct="$(basename "$(dirname "$(dirname "$vdf")")")"
            local rows cnt
            rows="$(list_shortcuts "$vdf")"
            cnt="$(printf '%s\n' "$rows" | grep -c . || true)"
            note "  账号 $acct：$cnt 条快捷方式（$vdf）"
            [ "$cnt" = 0 ] && continue
            roots_used=$((roots_used + 1))
            [ "$LIST_GAMES" = 1 ] && printf '  %-20s %-28s %s\n' "APPID" "名称" "注入链状态"

            while IFS=$'\t' read -r appid name exe startdir opts; do
                # 只跳过完全空的记录（appid 允许为空，便于解析器降级时仍能列出游戏）
                [ -z "${name}${exe}${opts}" ] && continue

                if [ "$LIST_GAMES" = 1 ]; then
                    local dir tag="-"
                    dir="$(exe_dir_of "$exe" 2>/dev/null || true)"
                    if is_doorstop_dir "$dir" 2>/dev/null; then
                        if has_winhttp_override "$root" "$opts" "$appid"; then tag="Doorstop/OK"
                        else tag="Doorstop/需修"; fi
                    fi
                    printf '  %-20s %-28s %s\n' "$appid" "${name:0:26}" "$tag"
                    n=$((n + 1))
                    continue
                fi

                # --all-games：只关心有注入链风险的
                if [ "$ALL_GAMES" = 1 ]; then
                    local dir2; dir2="$(exe_dir_of "$exe" 2>/dev/null || true)"
                    if is_doorstop_dir "$dir2" 2>/dev/null; then
                        ds_total=$((ds_total + 1))
                        if ! has_winhttp_override "$root" "$opts" "$appid"; then
                            ds_bad=$((ds_bad + 1))
                            warn "$name：Doorstop 注入器不会加载（启动项缺 winhttp=n,b）"
                            note "  启动项: ${opts:-<空>}"
                            note "  修法: 属性 → 启动选项 填 WINEDLLOVERRIDES=winhttp=n,b %command% <原有参数>"
                        fi
                    fi
                    n=$((n + 1))
                    continue
                fi

                # --game <关键词>
                local blob="$name $exe $startdir"
                if printf '%s' "$blob" | grep -qiF -- "$GAME_MATCH"; then
                    if [ -z "$LAUNCH_APPID" ]; then
                        LAUNCH_APPID="$appid"; LAUNCH_ROOT="$root"
                    fi
                    check_one_game "$root" "$appid" "$name" "$exe" "$opts"
                    n=$((n + 1))
                fi
            done <<<"$rows"
        done <<<"$(vdfs_of_root "$root")"

        if [ "$any_vdf" = 0 ]; then
            warn "$root 下没有找到 shortcuts.vdf（非 Steam 快捷方式就存在这里）"
            note "  目录 $root/userdata 内容：$(ls "$root/userdata" 2>/dev/null | tr '\n' ' ')"
            note "  如果你用 sudo 运行：脚本已尝试 SUDO_USER 的家目录；也可 STEAM_USERDATA=<数字> 指定账号"
        fi
    done

    vnote "共扫描 $n 条快捷方式，来自 $roots_used 个账号 / $vdfs_seen 个 shortcuts.vdf"
    if [ "$ALL_GAMES" = 1 ]; then
        if [ "${ds_bad:-0}" -gt 0 ]; then
            info "共 ${ds_total:-0} 个 Doorstop 注入游戏，其中 ${ds_bad} 个启动项缺 winhttp=n,b（见上面告警）"
        elif [ "${ds_total:-0}" -gt 0 ]; then
            ok "${ds_total} 个 Doorstop 注入游戏（BepInEx/汉化/Mod）的启动项都正常"
        else
            info "没有扫描到 Doorstop 注入游戏"
        fi
    fi
    if [ "$ALL_GAMES" = 0 ] && [ "$LIST_GAMES" = 0 ] && [ "$n" = 0 ]; then
        warn "没有匹配 \"$GAME_MATCH\" 的快捷方式（用 --list-games 看全部；--debug-steam 看解析过程）"
    fi
}

# ============================================================ Steam 诊断
# 用来看清楚"为什么没检测到快捷方式"：账号目录、每个 vdf 的大小/时间/条目数、
# 以及两种解析器（python3 / coreutils）各自解析出多少条。
debug_steam() {
    [ "$DEBUG_STEAM" = 1 ] || return 0
    sec "Steam 诊断（--debug-steam）"

    note "当前用户: $(id -un 2>/dev/null)（uid=$(id -u)）　HOME=$HOME　SUDO_USER=${SUDO_USER:-<无>}"
    note "Steam shortcuts.vdf 解析器: $(have python3 && printf 'python3（优先）' || printf '内置 coreutils（无 python3）')"

    if [ "${STEAM_ROOTS[*]:-}" = "" ]; then
        warn "一个 Steam 根目录都没探测到"
        note "候选路径：\$HOME/.local/share/Steam、\$HOME/.steam/{steam,root,debian-installation}、"
        note "          Flatpak 的 \$HOME/.var/app/com.valvesoftware.Steam/{data/Steam,.local/share/Steam}"
        note "可用 STEAM_DIR=/路径 手动指定；用 sudo 跑时会自动按 SUDO_USER 的家目录找"
        return
    fi

    local root vdf raw cnt
    for root in ${STEAM_ROOTS[@]+"${STEAM_ROOTS[@]}"}; do
        note "根目录: $root（$(steam_root_kind "$root")）"
        note "  steamapps: $([ -d "$root/steamapps" ] && printf 有 || printf 无)　userdata: $([ -d "$root/userdata" ] && printf 有 || printf 无)"
        [ -d "$root/userdata" ] && note "  账号目录: $(ls "$root/userdata" 2>/dev/null | tr '\n' ' ')"

        local any=0
        while IFS= read -r vdf; do
            [ -n "$vdf" ] || continue
            any=1
            raw="$(grep -abo -- 'appid' "$vdf" 2>/dev/null | grep -c . || true)"
            cnt="$(list_shortcuts "$vdf" | grep -c . || true)"
            note "  vdf: $vdf"
            note "       大小 $(wc -c < "$vdf" 2>/dev/null) 字节　改于 $(date -r "$vdf" '+%F %T' 2>/dev/null)"
            note "       原始条目数(appid 出现次数)=$raw　解析出=$cnt"
            [ "$raw" != "$cnt" ] && warn "  解析条数与原始条数不一致，可能解析器有问题（请把这段发我）"
        done <<<"$(vdfs_of_root "$root")"
        [ "$any" = 0 ] && note "  （这个根目录下没有 shortcuts.vdf）"
    done
    note "多账号时可用 STEAM_USERDATA=<数字> 只看某个账号；非 Steam 快捷方式只存在 shortcuts.vdf 里"
}

# ============================================================ 启动
# 启动方式按 Steam 安装形态选择：
#   · 原生 Steam（含 SteamOS 内置）→ steam -applaunch
#   · Flatpak 版 Steam           → flatpak run com.valvesoftware.Steam -applaunch
#   · 都不行                     → xdg-open steam://rungameid/<appid>（交给 URL 处理器）
spawn() {
    if have setsid; then setsid "$@" >/dev/null 2>&1 &
    else "$@" >/dev/null 2>&1 & fi
}

maybe_launch() {
    [ "$DO_LAUNCH" = 1 ] || return 0
    if [ -z "$LAUNCH_APPID" ]; then
        warn "没有可启动的目标（需要 --game 匹配到某个快捷方式）"
        return 0
    fi
    if [ "$WARNINGS" -gt 0 ] && [ "$ASSUME_YES" != 1 ]; then
        printf '  %s有警告，仍然启动吗？[y/N] %s' "$C_YEL" "$C_RST"
        local a=""; read -r a || true
        case "$a" in y|Y|yes|YES) ;; *) echo "  已取消。"; return 0 ;; esac
    fi

    echo "  → 正在启动（appid $LAUNCH_APPID）…"
    case "${LAUNCH_ROOT:-}" in
        */.var/app/com.valvesoftware.Steam/*)
            if have flatpak && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
                spawn flatpak run com.valvesoftware.Steam -applaunch "$LAUNCH_APPID"
                return 0
            fi
            ;;
    esac
    if have steam; then
        spawn steam -applaunch "$LAUNCH_APPID"
        return 0
    fi
    if have flatpak && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
        spawn flatpak run com.valvesoftware.Steam -applaunch "$LAUNCH_APPID"
        return 0
    fi
    if have xdg-open; then
        spawn xdg-open "steam://rungameid/$LAUNCH_APPID"
        return 0
    fi
    warn "找不到 steam / flatpak / xdg-open，请手动启动"
}

# ============================================================ 主流程
# 识别系统（SteamOS 有专门提示）、探测所有 Steam 安装（原生 / SteamOS / Flatpak）
_osid="$(awk -F= '/^ID=/{gsub(/"/, "", $2); print $2}' "$OS_RELEASE_FILE" 2>/dev/null)"
case "$_osid" in steamos|steamdeck) IS_STEAMOS=1 ;; esac
detect_steam_roots

echo "GPU / Proton 启动前体检　$(date '+%F %T')"
[ -r "$CONF_FILE" ] && vnote "配置文件: $CONF_FILE"
for _r in ${STEAM_ROOTS[@]+"${STEAM_ROOTS[@]}"}; do
    vnote "Steam: $_r（$(steam_root_kind "$_r")）"
done

# --list-games：只列快捷方式，不做系统体检（要体检就用 --all-games / --game）
if [ "$LIST_GAMES" = 1 ]; then
    check_games
    debug_steam
    echo
    echo "提示：--all-games 会对有注入链风险的快捷方式告警；--game <关键词> 做单游戏完整检查。"
    exit 0
fi

check_env
check_driver
check_memory
check_vulkan
check_games
debug_steam

echo
if [ "$CRITICAL" = 1 ]; then
    printf '%s✗ 结论：发现严重问题，先别启动。%s\n' "$C_RED" "$C_RST"
    echo "  → NVIDIA channel/GSP 损坏、或 AMD GPU reset 之后：请【重启电脑】"
    echo "    （重启会重置驱动的内存池 / GPU VA 空间 / GSP / channel 池，或让 amdgpu 重新初始化）"
    echo "  → 若是 nvidia-smi 不可用：多半是内核模块与用户态版本不一致，统一驱动包后重启"
    [ "$IS_STEAMOS" = 1 ] && echo "  → SteamOS 是不可变系统：驱动随系统镜像更新，别手动改 /usr；必要时切 Beta 通道等修复"
    exit 2
elif [ "$WARNINGS" -gt 0 ]; then
    printf '%s! 结论：有 %d 处警告，可以尝试启动，但建议先处理上面提示。%s\n' "$C_YEL" "$WARNINGS" "$C_RST"
    maybe_launch
    exit 1
else
    printf '%s✓ 结论：一切正常，放心启动。%s\n' "$C_GRN" "$C_RST"
    maybe_launch
    exit 0
fi
