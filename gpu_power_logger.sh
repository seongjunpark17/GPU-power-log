#!/usr/bin/env bash
set -euo pipefail

#====== Usage ======
usage() {
    cat <<-EOF
    Usage: $0 [METHOD]
    METHOD:
        gpustat : use 'gpustat' command to log power usage (interval: \${INTERVAL_gpustat:-1}s)
        pynvml  : use 'pynvml' python package to log power usage (interval: \${INTERVAL_pynvml:-0.1}s, minimum ~100ms)
    COMMAND:
        The command to run is specified by the CMD environment variable.
        If CMD is not set, a default example command is used.
    LOG_FILE:
        The log file to write power usage data. Default is 'power_log.csv'.
    ENVIRONMENT VARIABLES:
        CMD                     : The command to execute (e.g. 'python3 train.py')
        LOG_FILE                : CSV file to store power log (default: power_log.csv)
        INTERVAL_gpustat        : Sampling interval for gpustat (default: 1s)
        INTERVAL_pynvml         : Sampling interval for pynvml (default: 0.1s)
        DETECT_TIMEOUT          : Max seconds to detect GPU usage (default: 60s)
        START_MARK              : Marker string to trigger start of measurement (default: __BEGIN_MEASURE__)
        STOP_MARK               : Marker string to trigger end of measurement (default: __END_MEASURE__)
        MARK_TIMEOUT            : Timeout to wait for start marker (default: 60s)
        START_UTIL              : GPU utilization threshold to begin logging (default: 10%)
        START_CONSEC            : Required consecutive samples above threshold (default: 1)
        EARLY_EXIT_ON_STOP      : Exit immediately when STOP_MARK is seen (default: 1)
        KILL_MAIN_ON_STOP       : Kill main process when STOP_MARK is seen (default: 0)
        METHOD                  : Measurement method ('gpustat' or 'pynvml', default: pynvml)
	EOF
}

# ===== Common helpers =====
need() { command -v "$1" &>/dev/null || { echo "Error: need '$1'"; exit 1; }; }

# ----- PGID / PID Check -----
get_pgid() { ps -o pgid= -p "$CMD_PID" | awk '{print $1}'; }

# ----- collect all descendants recursively -----
collect_descendants() {
    local root="$1"
    local queue=("$root")
    local visited=()
    local out=()

    while ((${#queue[@]})); do
        local p="${queue[0]}"; queue=("${queue[@]:1}")
        [[ -n "$p" ]] || continue
        visited+=("$p")
        out+=("$p")

        mapfile -t children < <(pgrep -P "$p" 2>/dev/null || true)
        if ((${#children[@]})); then
            queue+=("${children[@]}")
        fi
    done

    printf "%s\n" "${out[@]}" | sort -un
}

# ----- Detect GPU for PID -----
find_gpu_index_for_pid() {
    local pid="$1"
    gpustat --json 2>/dev/null | jq -r --argjson pid "$pid" '
        [.gpus[] | select(.processes != null and any(.processes[]; .pid == $pid)) | .index]
        | join(" ")
    '
}

# ----- marker helpers -----
wait_for_start_marker() {
    echo "[WAIT] marker mode: waiting for '$START_MARK' in $CMD_LOG (timeout=${MARK_TIMEOUT}s)"
    if (( MARK_TIMEOUT > 0 )); then
        timeout "${MARK_TIMEOUT}s" bash -lc 'tail -Fn0 "'"$CMD_LOG"'" | stdbuf -o0 grep -m1 -F "'"$START_MARK"'"' >/dev/null
    else
        bash -lc 'tail -Fn0 "'"$CMD_LOG"'" | stdbuf -o0 grep -m1 -F "'"$START_MARK"'"' >/dev/null
    fi
    local rc=$?
    if (( rc != 0 )); then
        echo "[ERR] start marker not seen within timeout"
        return 1
    fi
    echo "[TRIGGER] start marker seen."
    return 0
}

spawn_stop_marker_watcher() {
    [[ -z "$STOP_MARK" ]] && return 0
    (
        until [[ -f "$CMD_LOG" ]]; do sleep 0.1; done

        if grep -Fq -- "$STOP_MARK" "$CMD_LOG" 2>/dev/null; then
            echo "[STOP] stop marker already present → stop logging"
            kill "$MONITOR_PID" 2>/dev/null || true
            [[ -n "$STOP_FLAG" ]] && echo "seen" > "$STOP_FLAG"
            (( KILL_MAIN_ON_STOP )) && kill "$CMD_PID" 2>/dev/null || true
            exit 0
        fi

        echo "[WATCH] waiting for stop marker '$STOP_MARK' in $CMD_LOG"

        tail -n0 -F -- "$CMD_LOG" 2>/dev/null \
            | sed -u 's/\r$//' \
            | grep -m1 -F --line-buffered -- "$STOP_MARK"

        echo "[STOP] stop marker seen → stop logging"
        kill "$MONITOR_PID" 2>/dev/null || true
        [[ -n "$STOP_FLAG" ]] && echo "seen" > "$STOP_FLAG"
        if (( KILL_MAIN_ON_STOP )); then
            kill "$CMD_PID" 2>/dev/null || true
        fi
    ) & echo $!
}

# ---- group utilization (max over target GPUs) ----
get_group_util_max() {
    local json="$1"
    local m=0
    for idx in "${TARGET_GPU_INDICES[@]}"; do
        local u
        u=$(jq -r --argjson idx "$idx" '.gpus[] | select(.index == $idx) | ."utilization.gpu"' <<<"$json" 2>/dev/null) || u=""
        [[ "$u" =~ ^[0-9]+$ ]] || u=0
        (( u>m )) && m=$u
    done
    echo "$m"
}

# ====== CSV Header ======
write_header_once() {
    if [[ ! -s "$LOG_FILE" ]]; then
        printf "timestamp" > "$LOG_FILE"
        for idx in "${TARGET_GPU_INDICES[@]}"; do
            printf ",GPU%s" "$idx" >> "$LOG_FILE"
        done
        printf "\n" >> "$LOG_FILE"
    fi
}

# ====== Monitoring Loops ======
monitor_loop_gpustat() {
    write_header_once
    while kill -0 "$CMD_PID" 2>/dev/null; do
        local json line pwr
        json=$(gpustat --json 2>/dev/null || echo '{}')
        line="$(date +%s.%3N)"
        for idx in "${TARGET_GPU_INDICES[@]}"; do
            pwr=$(jq -r --argjson idx "$idx" '
                .gpus[] | select(.index == $idx) | ."power.draw"
            ' <<< "$json")
            if [[ -z "$pwr" || "$pwr" == "null" ]]; then
                line+=","
            else
                line+=",$pwr"
            fi
        done
        echo "$line" >> "$LOG_FILE"
        sleep "$INTERVAL_gpustat"
    done
}

monitor_loop_pynvml() {
    write_header_once
    local args=("${TARGET_GPU_INDICES[@]}")
    while kill -0 "$CMD_PID" 2>/dev/null; do
        local csv
        csv=$(python3 use_pynvml_multi.py "${args[@]}" 2>/dev/null || true)
        echo "$(date +%s.%3N),${csv}" >> "$LOG_FILE"
        sleep "$INTERVAL_pynvml"
    done
}

# Returns the PID of the monitoring process
start_monitor() {
    case "$METHOD" in
        gpustat) monitor_loop_gpustat & echo $! ;;
        pynvml)  monitor_loop_pynvml  & echo $! ;;
        *) echo "[ERR] unknown method: $METHOD"; exit 1 ;;
    esac
}

# ====== High-level steps (for UI/structure) ======

check_dependencies() {
    need nvidia-smi
    need gpustat
    need jq
    need awk
    need ps
    need pgrep
    need timeout
    need stdbuf
    need tail
    need sed
    need grep
    [[ "$METHOD" == "pynvml" ]] && need python3
}

clear_logs() {
    echo "[Delete] old log: $LOG_FILE, ${LOG_FILE%.csv}_summary.csv, $CMD_LOG"
    rm -f "$LOG_FILE"
    rm -f "${LOG_FILE%.csv}_summary.csv"
    rm -f "$CMD_LOG"
}

run_command() {
    [[ -n "$CMD" ]] || { echo "Error: CMD is empty (set CMD=...)"; exit 1; }
    echo "[RUN] $CMD"
    eval "$CMD" >"$CMD_LOG" 2>&1 &
    CMD_PID=$!
    echo "[PID] parent: $CMD_PID"
}

detect_target_gpus() {
    TARGET_GPU_INDICES=()
    local PGID
    PGID=$(get_pgid)
    echo "[PGID] $PGID"
    echo "[WAIT] detecting GPUs used by the process group (timeout ${DETECT_TIMEOUT}s)"

    local i pid idx
    for ((i=0;i<DETECT_TIMEOUT;i++)); do
        mapfile -t ALLP < <(collect_descendants "$CMD_PID")

        for pid in "${ALLP[@]}"; do
            [[ -n "${pid:-}" ]] || continue
            read -ra indices <<< "$(find_gpu_index_for_pid "$pid" || true)"
            for idx in "${indices[@]}"; do
                if [[ -n "$idx" && ! " ${TARGET_GPU_INDICES[*]} " =~ " ${idx} " ]]; then
                    TARGET_GPU_INDICES+=("$idx")
                    echo "[DETECT] GPU ${idx} used by PID $pid"
                fi
            done
        done

        ((${#TARGET_GPU_INDICES[@]} > 0)) && break
        sleep 1
    done

    if ((${#TARGET_GPU_INDICES[@]} == 0)); then
        echo "[ERR] timed out: no GPUs detected"
        kill "$CMD_PID" 2>/dev/null || true
        exit 1
    fi
    echo "[GPU] target indices: ${TARGET_GPU_INDICES[*]}"
}

wait_util_gate() {
    echo "[WAIT] util gate: utilization >= ${START_UTIL}% (consec=${START_CONSEC}) ..."
    local hits=0 json gu
    while true; do
        json=$(gpustat --json 2>/dev/null || echo '{}')
        gu=$(get_group_util_max "$json")
        if [[ "$gu" =~ ^[0-9]+$ && "$gu" -ge "$START_UTIL" ]]; then
            hits=$((hits+1))
        else
            hits=0
        fi
        if (( hits >= START_CONSEC )); then
            echo "[START] util=${gu}% (>=${START_UTIL}%), begin logging."
            break
        fi
        sleep 1
    done
}

setup_stop_flag_and_watcher() {
    STOP_FLAG=""
    set +e
    local TMP_STOP_FLAG RC
    TMP_STOP_FLAG=$(mktemp -t gpu_power_stop.XXXXXX 2>/dev/null)
    RC=$?
    set -e
    if (( RC == 0 )); then
        STOP_FLAG="$TMP_STOP_FLAG"
    fi

    WATCHER_PID=$(spawn_stop_marker_watcher || true)
    [[ -n "${WATCHER_PID:-}" ]] && echo "[MON] stop-marker watcher pid: $WATCHER_PID"
}

wait_for_main_or_stop() {
    if [[ -n "${WATCHER_PID:-}" && -n "${STOP_FLAG:-}" && $EARLY_EXIT_ON_STOP -eq 1 ]]; then
        while true; do
            if [[ -e "$STOP_FLAG" ]]; then
                break
            fi
            if ! kill -0 "$CMD_PID" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done
        EXIT_CODE=0
    else
        set +e
        wait "$CMD_PID"
        EXIT_CODE=$?
        set -e
    fi
    echo "[DONE] main exit code = $EXIT_CODE"
}

stop_monitoring() {
    kill "$MONITOR_PID" 2>/dev/null || true
    [[ -n "${WATCHER_PID:-}" ]] && kill "$WATCHER_PID" 2>/dev/null || true
    [[ -n "${STOP_FLAG:-}" ]] && rm -f "$STOP_FLAG" 2>/dev/null || true
    END_TIME=$(date +%s.%3N)
    sleep 0.2
}

compute_summary() {
    if [[ ! -s "$LOG_FILE" ]]; then
        echo "[WARN] empty log (job ended too quickly?)"
        return
    fi

    # Average over time and GPUs
    local result
    result=$(awk -F',' '
    NR==1 {
        for (i=2; i<=NF; i++) name[i]=$i
        next
    }
    {
        for (i=2; i<=NF; i++) {
            if ($i != "") { sum[i]+=$i; cnt[i]++ }
        }
    }
    END {
        out = ""
        for (i=2; i<=NF; i++) {
            if (cnt[i]>0) {
                val = sum[i]/cnt[i]
                out = (out == "") ? sprintf("%.3f", val) : out "," sprintf("%.3f", val)
            } else {
                out = (out == "") ? "NA" : out ",NA"
            }
        }
        print out
    }
    ' "$LOG_FILE")

    TOTAL_TIME=$(awk -F',' 'NR==2{start=$1} {last=$1} END{if(start!="" && last!="") printf "%.3f", last-start; else print "0.000"}' "$LOG_FILE")

    IFS=',' read -ra values <<< "$result"

    ENERGIES=()
    TOTAL_ENERGY=0
    local i val energy
    for i in "${!TARGET_GPU_INDICES[@]}"; do
        val="${values[$i]}"
        if [[ -z "$val" || "$val" == "NA" ]]; then
            ENERGIES+=("NA")
            continue
        fi
        energy=$(awk -v p="$val" -v t="$TOTAL_TIME" 'BEGIN{printf "%.3f", p*t}')
        ENERGIES+=("$energy")
        TOTAL_ENERGY=$(awk -v a="$TOTAL_ENERGY" -v b="$energy" 'BEGIN{printf "%.3f", a+b}')
    done

    # Average power across all GPUs (ignore NA)
    local sum=0
    local count=0
    local v
    for v in "${values[@]}"; do
        if [[ -z "$v" || "$v" == "NA" ]]; then
            continue
        fi
        sum=$(awk -v s="$sum" -v x="$v" 'BEGIN{printf "%.3f", s + x}')
        count=$((count+1))
    done

    if (( count > 0 )); then
        AVG_POWER_ALL=$(awk -v s="$sum" -v n="$count" 'BEGIN{printf "%.3f", s/n}')
    else
        AVG_POWER_ALL="NA"
    fi

    # ---- Summary CSV ----
    SUMMARY_FILE="${LOG_FILE%.csv}_summary.csv"
    if [[ ! -s "$SUMMARY_FILE" ]]; then
        echo "metric,gpu_index,value,unit" > "$SUMMARY_FILE"
    fi

    # Total time
    echo "TIME,ALL,${TOTAL_TIME},sec" >> "$SUMMARY_FILE"

    # Power per GPU
    for i in "${!TARGET_GPU_INDICES[@]}"; do
        local gi="${TARGET_GPU_INDICES[$i]}"
        echo "POWER,${gi},${values[$i]},W" >> "$SUMMARY_FILE"
    done

    # Energy per GPU
    for i in "${!TARGET_GPU_INDICES[@]}"; do
        local gi="${TARGET_GPU_INDICES[$i]}"
        echo "ENERGY,${gi},${ENERGIES[$i]},J" >> "$SUMMARY_FILE"
    done

    # Average power across all GPUs
    echo "POWER_ALL_AVG,ALL,${AVG_POWER_ALL},W" >> "$SUMMARY_FILE"
    echo "ENERGY_TOTAL,ALL,${TOTAL_ENERGY},J" >> "$SUMMARY_FILE"

    echo "[INFO] Total measurement duration: ${TOTAL_TIME}s"
    echo "Results appended to $LOG_FILE"
    echo "Summary written to $SUMMARY_FILE"
    echo "[INFO] Command log saved at: $CMD_LOG"
}

print_summary() {
    echo
    echo "================ GPU Power Measurement Summary ================="
    echo

    # read all lines (skip header)
    declare -a time_lines power_lines energy_lines total_lines
    local metric gpu value unit line
    while IFS=',' read -r metric gpu value unit; do
        [[ "$metric" == "metric" ]] && continue
        case "$metric" in
            TIME) time_lines+=("$gpu $value $unit") ;;
            POWER) power_lines+=("$gpu $value $unit") ;;
            ENERGY) energy_lines+=("$gpu $value $unit") ;;
            POWER_ALL_AVG|ENERGY_TOTAL) total_lines+=("$metric $gpu $value $unit") ;;
        esac
    done < "$SUMMARY_FILE"

    # === TIME ===
    echo "[TIME]"
    for line in "${time_lines[@]}"; do
        read -r gpu value unit <<< "$line"
        printf "  %-6s %-12s %s\n" "$gpu" "$value" "$unit"
    done
    echo

    # === POWER ===
    echo "[AVERAGE POWER per GPU]"
    for line in "${power_lines[@]}"; do
        read -r gpu value unit <<< "$line"
        printf "  GPU%-4s %-12s %s\n" "$gpu" "$value" "$unit"
    done
    echo

    # === ENERGY ===
    echo "[TOTAL ENERGY per GPU]"
    for line in "${energy_lines[@]}"; do
        read -r gpu value unit <<< "$line"
        printf "  GPU%-4s %-12s %s\n" "$gpu" "$value" "$unit"
    done
    echo

    # === TOTALS ===
    echo "[SUMMARY]"
    for line in "${total_lines[@]}"; do
        read -r metric gpu value unit <<< "$line"
        printf "  %-15s %-6s %-12s %s\n" "$metric" "$gpu" "$value" "$unit"
    done
    echo
    echo "================================================================="
}

main() {
    # Help
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        return 0
    fi

    # ====== Settings ======
    CMD=${CMD:-"CUDA_VISIBLE_DEVICES=0,1 python3 example_multi_GPU.py"}
    LOG_FILE=${LOG_FILE:-"power_log.csv"}
    CMD_LOG="cmd_output.log"

    INTERVAL_gpustat=${INTERVAL_gpustat:-1}     # seconds
    INTERVAL_pynvml=${INTERVAL_pynvml:-0.1}     # seconds
    DETECT_TIMEOUT=${DETECT_TIMEOUT:-60}        # seconds
    METHOD=${1:-pynvml}                         # gpustat | pynvml

    # ====== Marker-only ======
    START_MARK=${START_MARK:-__BEGIN_MEASURE__}
    STOP_MARK=${STOP_MARK:-__END_MEASURE__}
    MARK_TIMEOUT=${MARK_TIMEOUT:-60}

    START_UTIL=${START_UTIL:-10}                 # Minimum utilization (%) to start logging
    START_CONSEC=${START_CONSEC:-1}              # Start logging after N consecutive checks meeting the utilization threshold

    EARLY_EXIT_ON_STOP=${EARLY_EXIT_ON_STOP:-1}   # If 1, exit when STOP_MARK is seen
    KILL_MAIN_ON_STOP=${KILL_MAIN_ON_STOP:-0}     # If 1, kill main process when STOP_MARK is seen

    check_dependencies
    clear_logs
    run_command

    # Start by marker, then util gate
    wait_for_start_marker || { kill "$CMD_PID" 2>/dev/null || true; return 1; }
    detect_target_gpus
    wait_util_gate

    # Time tracking (not currently used in summary, but kept for future UI)
    START_TIME=$(date +%s.%3N)

    # Start monitoring
    MONITOR_PID=$(start_monitor)
    echo "[MON] logger pid: $MONITOR_PID"

    setup_stop_flag_and_watcher
    wait_for_main_or_stop
    stop_monitoring

    compute_summary
    [[ -f "${LOG_FILE%.csv}_summary.csv" ]] && print_summary

    return "$EXIT_CODE"
}

main "$@"
exit "$?"
