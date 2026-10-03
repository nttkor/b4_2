#!/bin/bash
# ==============================================================================
# 파일명    : bin/monitor.sh
# 프로그램명 : agent-app-leak 전용 프로세스 및 시스템 리소스 관제 스크립트
# 작성목적  :
#   1. 대상 프로세스(agent-app-leak)의 생존 여부(PID) 및 포트(15034) 바인딩 감시
#   2. 프로세스 수준의 정밀 리소스(CPU %, RSS 메모리 MB 및 점유율 %) 실시간 수집
#   3. 스레드(LWP) 레벨 상태(STAT, TID) 진단을 통한 교착상태(Deadlock) 탐지
#   4. 호스트 파일시스템 디스크 잔여 용량 및 방화벽(UFW) 보안 상태 검사
#   5. 이상 징후 발생 시 임계치(CPU > 80%, MEM > 30%) 자동 경보(WARNING) 출력
#   6. 10MB 단위 자동 로그 로테이션(Log Rotation)을 통한 디스크 고갈 방지
#
# 환경변수 요구사항:
#   - AGENT_APP_NAME : 관제 대상 프로세스명 (기본값: agent-app-leak)
#   - AGENT_PORT     : 서비스 리스닝 포트 (기본값: 15034)
#   - AGENT_LOG_DIR  : 로그 저장 디렉터리 (기본값: /var/log/agent-app)
#
# 출력 로그 포맷:
#   [YYYY-MM-DD HH:MM:SS] PROCESS:<이름> PID:<PID> CPU:<X>% MEM:<X>MB(<X>%) DISK:<X>G FIREWALL:<상태>
#
# 실행 방법:
#   - 단발 수동 실행 : ./bin/monitor.sh
#   - crontab 등록  : * * * * * AGENT_PORT=15034 AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor-cron.log 2>&1
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 환경 설정 및 전역 변수 초기화
# ------------------------------------------------------------------------------
# 셸 매개변수 확장 문법(${VAR:-DEFAULT})을 사용하여 환경변수가 설정되지 않은 경우 안전한 기본값 할당
APP_NAME="${AGENT_APP_NAME:-agent-app-leak}"           # 관제 대상 프로세스 실행 파일명
APP_PORT="${AGENT_PORT:-15034}"                       # 애플리케이션 서비스 리스닝 포트 (부트 4단계 검증용)
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"        # 관제 로그가 저장될 기본 디렉터리
LOG_FILE="${LOG_DIR}/monitor.log"                     # 관제 결과가 한 줄 요약으로 누적 기록될 로그 파일

# 로그 로테이션 정책 설정
MAX_LOG_SIZE=$((10 * 1024 * 1024))                    # 단일 로그 파일의 최대 허용 크기 (10MB = 10,485,760 Bytes)
MAX_LOG_FILES=10                                      # 보관할 최대 백업 로그 파일 개수 (.1 ~ .10)

# 관측 시점 타임스탬프 (YYYY-MM-DD HH:MM:SS 표준 포맷)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# ------------------------------------------------------------------------------
# 2. 로그 로테이션(Log Rotation) 함수
# ------------------------------------------------------------------------------
# 목적: monitor.log 파일이 10MB를 초과할 경우, 디스크 풀(Disk Full)을 방지하기 위해
#      기존 백업 로그들을 뒤로 한 칸씩 밀어내고 새 로그 파일을 생성함.
rotate_log() {
    # 대상 로그 파일이 아직 생성되지 않은 초기 상태라면 로테이션 건너뜀
    [ -f "$LOG_FILE" ] || return

    local size
    # stat 명령어를 사용하여 로그 파일의 정확한 바이트 단위 크기 측정 (실패 시 0 처리)
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)

    # 현재 파일 크기가 임계치(10MB) 이하인 경우 로테이션 생략
    [ "$size" -le "$MAX_LOG_SIZE" ] && return

    # 최대 보관 개수를 초과한 가장 오래된 백업 파일(.10)이 존재하면 영구 삭제
    [ -f "${LOG_FILE}.${MAX_LOG_FILES}" ] && rm -f "${LOG_FILE}.${MAX_LOG_FILES}"

    # 기존 백업 파일들을 역순으로 한 단계씩 시프트 (.9 -> .10, .8 -> .9, ..., .1 -> .2)
    for i in $(seq $((MAX_LOG_FILES - 1)) -1 1); do
        [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    done

    # 현재 활성 로그 파일(monitor.log)을 1차 백업본(.1)으로 전환
    mv "$LOG_FILE" "${LOG_FILE}.1"
}

# ------------------------------------------------------------------------------
# 3. 콘솔 출력 헤더
# ------------------------------------------------------------------------------
echo "====== SYSTEM MONITOR RESULT ======"
echo "Time: ${TIMESTAMP}"
echo ""

# ------------------------------------------------------------------------------
# 4. [HEALTH CHECK] 프로세스 생존 및 네트워크 포트 검사
# ------------------------------------------------------------------------------
echo "[HEALTH CHECK]"

# pgrep -f: 전체 명령행 인수를 검색하여 대상 프로세스의 PID를 추출 (첫 번째 PID만 선택)
PID=$(pgrep -f "$APP_NAME" | head -1)

# 프로세스가 실행 중이지 않은 경우: 에러 출력 후 자원 수집을 중단하고 종료 코드 1 반환
if [ -z "$PID" ]; then
    echo "Process '${APP_NAME}'... [FAIL] (Not running)"
    echo ""
    echo "[INFO] Process not found — skipping resource collection."
    echo "===================================="
    exit 1
fi
echo "Process '${APP_NAME}'... [OK] (PID: ${PID})"

# ss -tulnp: TCP/UDP 리스닝 포트를 조회하여 해당 포트(15034)가 정상 바인딩되었는지 정규표현식 검사
#   - :${APP_PORT}[[:space:]] : 포트 번호 뒤에 공백이 오는 패턴 매칭
#   - :${APP_PORT}$           : 줄 끝에 포트 번호가 위치하는 패턴 매칭
if ss -tulnp 2>/dev/null | grep -qE ":${APP_PORT}[[:space:]]|:${APP_PORT}$"; then
    echo "Port ${APP_PORT}... [OK]"
else
    # 포트가 아직 열리지 않았거나 크래시된 경우 경고 출력
    echo "Port ${APP_PORT}... [WARN] (Not listening — process may be initializing or crashed)"
fi
echo ""

# ------------------------------------------------------------------------------
# 5. [PROCESS RESOURCE MONITORING] 프로세스 및 시스템 리소스 정밀 수집
# ------------------------------------------------------------------------------
echo "[PROCESS RESOURCE MONITORING]"

# [CPU 사용률 수집]
# ps -p "$PID" -o %cpu= : 특정 PID의 CPU 점유율(%)을 헤더 없이 순수 수치로 추출 후 공백 제거
PROC_CPU=$(ps -p "$PID" -o %cpu= 2>/dev/null | tr -d ' ')

# [메모리 상주 크기(RSS) 및 점유율 수집]
# ps -p "$PID" -o rss=  : 실제 물리 RAM에 적재된 상주 메모리(Resident Set Size)를 KB 단위 숫자로 추출
# awk '{printf "%.0f", $1/1024}' : 추출된 KB 값을 1024로 나누어 직관적인 정수 MB 단위로 환산
PROC_MEM_MB=$(ps -p "$PID" -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
# ps -p "$PID" -o %mem= : 시스템 전체 물리 RAM 대비 프로세스의 백분율 점유율 추출
PROC_MEM_PCT=$(ps -p "$PID" -o %mem= 2>/dev/null | tr -d ' ')

# [호스트 루트 파일시스템 디스크 잔여량 및 사용률 수집]
# df / : 루트 파티션의 디스크 상태 조회
# 4번째 컬럼(가용 1KB 블록)을 1024^2로 나누어 기가바이트(GB) 정수로 변환
DISK_AVAIL=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
# 5번째 컬럼(사용률 %)에서 '%' 문자를 제거하여 순수 정수 값으로 추출
DISK_USED_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

# [호스트 방화벽(UFW) 상태 점검]
FIREWALL_STATUS="inactive"
if command -v ufw &>/dev/null; then
    # ufw 명령어가 존재하고 status 출력에 'active'가 포함된 경우 활성화로 판정
    ufw status 2>/dev/null | grep -qi "active" && FIREWALL_STATUS="active"
fi

# 수집된 정량 지표 터미널 출력
echo "CPU (process)  : ${PROC_CPU}%"
echo "MEM (process)  : ${PROC_MEM_MB}MB (${PROC_MEM_PCT}%)"
echo "DISK (avail)   : ${DISK_AVAIL}G  (used: ${DISK_USED_PCT}%)"
echo "Firewall       : ${FIREWALL_STATUS}"
echo ""

# ------------------------------------------------------------------------------
# 6. [THREAD INFO] 스레드(LWP) 레벨 상태 진단 (Deadlock 감시용)
# ------------------------------------------------------------------------------
# ps -p "$PID" -L: 프로세스에 속한 모든 경량 프로세스(LWP, 스레드) 목록 출력
# 전체 스레드 수 카운트
THREAD_COUNT=$(ps -p "$PID" -L --no-headers 2>/dev/null | wc -l)
echo "[THREAD INFO]"
echo "Thread count   : ${THREAD_COUNT}"

# 스레드별 상세 정보 출력 (TID: 스레드ID, STAT: 상태 플래그, PCPU: CPU%, PMEM: MEM%)
# Deadlock 발생 시 스레드들이 'Sl'(Sleep) 상태로 머물며 CPU 0.0%로 고착되는 패턴을 포착함
ps -p "$PID" -L -o pid,tid,stat,pcpu,pmem --no-headers 2>/dev/null | head -10
echo ""

# ------------------------------------------------------------------------------
# 7. [WARNINGS] 임계치 기반 이상 징후 자동 평가 및 경보
# ------------------------------------------------------------------------------
# Bash는 기본적으로 부동소수점(실수) 연산을 지원하지 않으므로, awk의 BEGIN 블록을 활용하여 조건 평가
# 조건이 거짓(!=0)이면 awk는 1을 반환(exit 1)하여 뒤의 echo가 실행되지 않고, 참(1)일 때만 echo 실행

# CPU 사용률 80% 초과 경보 (CPU Spike / 연산 독점 감지)
awk "BEGIN {exit !(${PROC_CPU} > 80)}"  && echo "[WARNING] Process CPU  > 80%  (${PROC_CPU}%)"

# 프로세스 메모리 점유율 30% 초과 경보 (Memory Leak / OOM 위험 감지)
awk "BEGIN {exit !(${PROC_MEM_PCT} > 30)}" && echo "[WARNING] Process MEM  > 30%  (${PROC_MEM_MB}MB / ${PROC_MEM_PCT}%)"

# 디스크 사용률 80% 초과 경보 (스토리지 고갈 방지)
[ "${DISK_USED_PCT}" -gt 80 ] && echo "[WARNING] Disk used > 80% (${DISK_USED_PCT}%)"

# 방화벽 비활성화 보안 경보
[ "${FIREWALL_STATUS}" = "inactive" ] && echo "[WARNING] Firewall is inactive!"

# ------------------------------------------------------------------------------
# 8. [LOG WRITE] 관제 로그 파일 기록 및 로테이션 수행
# ------------------------------------------------------------------------------
# 로그 저장 디렉터리가 없을 경우 자동 생성 (-p 옵션으로 상위 디렉터리까지 일괄 생성)
mkdir -p "$LOG_DIR"

# 로그 파일 크기 점검 및 필요 시 로테이션 수행
rotate_log

# 정규화된 관제 로그 포맷으로 monitor.log에 한 줄 추가(Append)
echo "[${TIMESTAMP}] PROCESS:${APP_NAME} PID:${PID} CPU:${PROC_CPU}% MEM:${PROC_MEM_MB}MB(${PROC_MEM_PCT}%) DISK:${DISK_AVAIL}G FIREWALL:${FIREWALL_STATUS}" >> "$LOG_FILE"
echo "[INFO] Log appended: ${LOG_FILE}"
echo "===================================="

# 정상 종료 코드 반환
exit 0
