# GPU-power-logger
GPU power logger
- GPU를 사용하는 코드의 전력 및 에너지량을 측정하는 코드입니다.
- 두 가지 측정 방식을 제공합니다:
    - gpustat 기반 (저속, 1초 간격)
    - pynvml 기반 (고속, 약 0.1초 간격)

## **필요 패키지**

```bash
# Python
pip install pynvml gpustat

# Conda
conda install jq
pip install gpustat pynvml psutil
```

---

## **실행 형식**

```
bash gpu_power_logger.sh [METHOD]
```

### **METHOD**

- gpustat : gpustat 명령어를 이용한 전력 측정 (기본 간격: 1초)
- pynvml : pynvml Python 라이브러리를 이용한 전력 측정 (기본 간격: 0.1초)

예시:

```
bash gpu_power_logger.sh gpustat
bash gpu_power_logger.sh pynvml (default)
```

---

## Store Configuration

| **변수명** | **설명** | **기본값** | line |
| --- | --- | --- | --- |
| CMD | 실행할 명령어 (측정 대상 프로그램) | - | 40 |
| LOG_FILE | 전력 로그 파일 이름 (csv) | `power_log.csv` | 41 |
| CMD_LOG | 명령어 출력 로그 저장 경로 | `cmd_output.log` | 42 |
| INTERVAL_gpustat | gpustat 사용 시 측정 간격 (초) | 1 | 44 |
| INTERVAL_pynvml | pynvml 사용 시 측정 간격 (초) | 0.1 | 45 |
| DETECT_TIMEOUT | GPU 탐지 최대 대기 시간 (초) | 60 | 46 |
| START_MARK | 로그 시작을 알리는 마커 문자열 | `__BEGIN_MEASURE__` | 50 |
| STOP_MARK | 로그 종료를 알리는 마커 문자열 | `__END_MEASURE__` | 51 |
| MARK_TIMEOUT | 시작 마커 감지 대기 시간 (s) | 60 (s) | 52 |
| START_UTIL | Util이 일정 이상일 때부터 로깅 시작 | 10 (%) | 54 |
| EARLY_EXIT_ON_STOP | 종료 마커 감지 시 로깅 조기 종료 여부  | (1: 종료, 0: 무시) | 57 |
| KILL_MAIN_ON_STOP | 종료 마커 감지 시 강제 종료 여부 | 0 | 58 |

---

## Usage example (Default)

- CMD의 명령어가 자동 실행되며, GPU 전력 사용량이 power_log.csv에 저장됩니다.

```
bash gpu_power_logger.sh pynvml
```

- usage를 출력합니다.

```python
bash gpu_power_logger.sh -h
```

```
Usage: gpu_power_logger.sh [METHOD]
METHOD:
    gpustat : use 'gpustat' command to log power usage (interval: 1s)
    pynvml  : use 'pynvml' python package to log power usage (interval: 0.1s, minimum ~100ms)
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
```

### Custom Usage example

1. Add marker
    - 측정하고자 하는 코드 부분을 위의 설정에서 지정했던 START_MARK와 STOP_MARK사이에 놓습니다.
    
    ```python
    # train.py (Example)
    def warmup(): ...
    def real_train(): ... # Target Function
    
    if __name__ == "__main__":
        warmup()
        print("__BEGIN_MEASURE__", flush=True)
        real_train() # Between Markers
        print("__END_MEASURE__", flush=True)
    ```
    
    - Target 함수를 Start marker와 Stop marker 사이에 위치시킵니다.
    - `flush=True`를 같이 작성해야 출력이 되어서 cmd_output.log에 기록이 남습니다.
    - marker는 위의 변수 지정에서 변경 가능합니다.
    
2. Execute code
    
    ```
    CMD="CUDA_VISIBLE_DEVICES=2 python3 train.py" \
    LOG_FILE="log.csv" \
    bash gpu_power_logger.sh gpustat
    ```
    
    - GPU 2번을 사용하여 train.py 실행
    - 전력 로그: log.csv
    - 요약 로그: log_summary.csv

---

## Storing

- **cmd_output.log** → 실행 명령어 출력 로그 저장.
- **power_log.csv** → 시간별 측정된 전력 사용량 (단위: W)
- **power_log_summary.csv** → 최종 요약 결과 (단위: W, J, sec)

---

## Calculation

| **항목** | **계산식** | **단위** |
| --- | --- | --- |
| 평균 전력 (GPU별) | Σ(P) / N | W |
| 총 에너지 (GPU별) | Power × time | J |
| 전체 평균 전력 | 모든 GPU 전력 평균 | W |
| 전체 에너지 | 모든 GPU 에너지 합 | J |

---

## Code flow

1. **명령 실행 및 PID 추적**
    - 지정된 `CMD`를 백그라운드로 실행하고 PID 추적
    - 실행 로그(`stdout`, `stderr`)를 `cmd_output.log`에 저장
    - 실행 프로세스의 PGID를 추출하여 하위 프로세스 전체를 추적
2. **Start Marker 감시 (**`__BEGIN_MEASURE__`**)**
    - `cmd_output.log`에서 `START_MARK`가 출력될 때까지 대기
    - `MARK_TIMEOUT`(기본 60초) 내에 감지되지 않으면 종료
3. **GPU 자동 탐지**
    - `gpustat --json`을 주기적으로 확인하며, 프로세스가 사용하는 GPU 자동 탐색
    - PID가 연결된 GPU 인덱스를 `TARGET_GPU_INDICES` 배열에 저장
4. **Utilization Gate Trigger**
    - 지정된 GPU의 활용률(`utilization.gpu`)이 `START_UTIL`(기본 10%) 이상이 되는 시점부터 로깅 시작
    - `START_CONSEC` 값만큼 연속으로 기준을 만족해야 로깅 시작 확정
5. **전력 로깅 루프**
    - 선택한 `METHOD`에 따라 다음 중 하나로 주기적 로깅 수행
        - `gpustat`: 약 1초 간격
        - `pynvml`: 약 0.1초 간격
    - GPU별 `power.draw` 값을 CSV(`power_log.csv`)에 저장
6. **Stop Marker 감시 (**`__END_MEASURE__`**)**
    - 별도 watcher 프로세스가 `cmd_output.log`에서 `STOP_MARK`를 실시간 감시
    - 감지 시 즉시 로깅 종료 (`EARLY_EXIT_ON_STOP=1` 설정 시)
7. **결과 계산 및 요약**
    - 로그 파일로부터 GPU별 평균 전력(W), 총 에너지(J), 실행 시간(s) 계산
    - 결과를 `power_log_summary.csv`에 저장하고 터미널에도 포맷된 형태로 출력

---

## Terminal Output Example

```
================ GPU Power Measurement Summary =================

[TIME]
  ALL    14.155       sec

[AVERAGE POWER per GPU]
  GPU0    298.969      W
  GPU1    297.089      W

[TOTAL ENERGY per GPU]
  GPU0    4231.906     J
  GPU1    4205.295     J

[SUMMARY]
  POWER_ALL_AVG   ALL    298.029      W
  ENERGY_TOTAL    ALL    8437.201     J

=================================================================
```

---

## Caution

- use_pynvml_multi.py 파일이 **같은 디렉토리**에 있어야 합니다. (pynvml method 측정시 사용)
- 실행 프로그램(CMD)이 GPU를 사용하지 않으면 detection fail로 종료됩니다.
- 로그가 비어 있으면 실행 시간이 너무 짧았거나 GPU 사용이 감지되지 않은 경우입니다.
- 로그 파일은 매 실행시 삭제됩니다. (line 67, 68, 69)

[gpu_power_logger.zip](attachment:dd7d70fe-5baf-4742-8d7e-543d61a01c17:gpu_power_logger.zip)
