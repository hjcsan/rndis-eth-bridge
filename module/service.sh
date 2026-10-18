#!/system/bin/sh
# late_start：等系统启动完成后再拉起守护，避免与 netd / EthernetTracker 初始化竞争
MODDIR=${0%/*}
LOG="$MODDIR/eth.log"
PIDFILE="$MODDIR/eth.pid"
DAEMON="$MODDIR/rndis-eth-daemon.sh"

# 等开机完成（最多 4 分钟）
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
    sleep 2
    i=$((i + 1))
done
sleep 5

# 找守护进程的真实 PID。
# 不能用 pidof（sh 是公共解释器，会匹配到一堆无关进程），
# 也不能只信 pid 文件（可能已失效），必须按 /proc/<pid>/cmdline 精确匹配完整路径。
find_daemon() {
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        # /proc 下可能有 /proc/8350_reg 这类非进程目录，必须校验纯数字
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        # 进程可能在遍历时退出，先确认可读再把错误全部吞掉
        [ -r "${p}/cmdline" ] || continue
        cmd=$(cat "${p}/cmdline" 2>/dev/null | tr '\0' ' ' 2>/dev/null)
        [ -z "$cmd" ] && continue
        # 必须【以 sh 开头】且命令行里含守护脚本名，才算守护进程，
        # 否则 `bash -c "...rndis-eth-daemon.sh..."` 这类外层命令也会被误认。
        case "$cmd" in
            sh\ *rndis-eth-daemon.sh*) echo "$pid" ;;
        esac
    done
}

# 杀掉所有已有的守护进程（多实例会互相干扰，日志也会重复）
old=$(find_daemon)
if [ -n "$old" ]; then
    for p in $old; do
        kill "$p" 2>/dev/null
    done
    sleep 1
    old=$(find_daemon)
    for p in $old; do
        kill -9 "$p" 2>/dev/null
    done
    sleep 1
fi
rm -f "$PIDFILE"

# 守护脚本把日志写到 /data/adb/rndis_eth.log，这里做一份软链方便查看
rm -f "$LOG"
: > /data/adb/rndis_eth.log
ln -sf /data/adb/rndis_eth.log "$LOG" 2>/dev/null

nohup sh "$DAEMON" >/dev/null 2>&1 &
launcher=$!

# 等守护把自己写进 pid 文件（最多约 3 秒）
i=0
while [ $i -lt 30 ] && [ ! -s "$PIDFILE" ]; do
    sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
done

# 以 cmdline 精确匹配的结果为准，pid 文件只是缓存
real=$(find_daemon)
if [ -n "$real" ]; then
    echo "$real" > "$PIDFILE" 2>/dev/null
    echo "$(date '+%m-%d %H:%M:%S') 守护已启动 pid=$real（启动器 $launcher）" >> /data/adb/rndis_eth.log
else
    echo "$(date '+%m-%d %H:%M:%S') 守护启动失败（未找到进程）" >> /data/adb/rndis_eth.log
fi
