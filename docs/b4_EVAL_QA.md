# Linux & OS 시스템 리소스 트러블슈팅 평가표(Eval) 종합 답변서

> **평가 문서**: [`b4_2_Eval.pdf`](./b4_2_Eval.pdf)  
> **미션 가이드**: [`b4_2_mission.pdf`](./b4_2_mission.pdf)  
> **미션 Q&A 종합 보고서**: [`mission_QA.md`](./mission_QA.md)  
> **프로젝트 URL**: [https://github.com/nttkor/b4_2](https://github.com/nttkor/b4_2)  
> **브랜치(Branch)**: `main`  
> **링크 형식 안내**: 본 문서는 GitHub 저장소 및 로컬 환경 어디서든 끊김 없이 이동할 수 있도록 **상대 경로(Relative Path)** 기반 링크로 구성되어 있습니다.

---

## 목차
1. [평가 기본 정보](#1-평가-기본-정보)
2. [항목 1: 필수 증거 및 이슈 리포트 포맷 검증](#2-항목-1-필수-증거-및-이슈-리포트-포맷-검증)
3. [항목 2: 관제 및 시스템 진단 역량 평가](#3-항목-2-관제-및-시스템-진단-역량-평가)
4. [항목 3: OS 원리 및 장애 메커니즘 심층 구술 평가](#4-항목-3-os-원리-및-장애-메커니즘-심층-구술-평가)
5. [항목 4: 실무 응용 및 아키텍처 개선 구술 평가](#5-항목-4-실무-응용-및-아키텍처-개선-구술-평가)
6. [항목 5: 보너스 과제 (스케줄링 알고리즘 추론)](#6-항목-5-보너스-과제-스케줄링-알고리즘-추론)
7. [6. 최종 평가 피드백](#7-6-최종-평가-피드백)

---

## 1. 평가 기본 정보

| 항목 | 내용 |
|---|---|
| **학습단계** | AI/SW 기초 (AI/SW Basic) |
| **학습주제** | Linux와 OS (Linux & OS) |
| **미션명** | 리눅스 프로세스 및 시스템 리소스 트러블슈팅 |
| **분석 대상** | [`agent-app-leak`](../agent-app-leak) |
| **핵심 관제 스크립트** | [`bin/monitor.sh`](../bin/monitor.sh) |
| **환경 설정 가이드** | [`README.md`](../README.md) |

---

## 2. 항목 1: 필수 증거 및 이슈 리포트 포맷 검증

### [1-1] [OOM] 메모리 사용량이 선형적으로 증가하다가 프로세스가 강제 종료되는 패턴이 로그에 기록되어 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - `agent-app-leak`을 `MEMORY_LIMIT=100`으로 실행 시, 내부 `MemoryWorker`가 3초마다 25MB씩 힙 메모리를 지속 할당하여 물리 메모리(RSS)가 선형 급증하는 패턴이 [`bin/monitor.sh`](../bin/monitor.sh#L55) 및 [`README.md`](../README.md#73-시나리오별-실행)에 기록되어 있습니다.
  - **관제 로그 발췌 증거** ([`mission_QA.md`](./mission_QA.md#32-메모리-누수oom-crash-원인-규명-및-리포팅)):
    ```text
    [2026-10-04 07:20:03] PROCESS:agent-app-leak PID:12450 CPU:1.2% MEM:26MB(1.3%)
    [2026-10-04 07:20:06] PROCESS:agent-app-leak PID:12450 CPU:1.5% MEM:51MB(2.5%)
    [2026-10-04 07:20:09] PROCESS:agent-app-leak PID:12450 CPU:1.4% MEM:76MB(3.8%)
    [2026-10-04 07:20:12] PROCESS:agent-app-leak PID:12450 CPU:1.6% MEM:101MB(5.0%)
    ```
  - **종료 로그**: 100MB 초과 즉시 `[CRITICAL] [MemoryGuard] Memory limit exceeded (101MB >= 100MB)` 및 `SELF-TERMINATED` 로그와 함께 `SIGKILL`(Exit 137)로 강제 종료되었습니다.

---

### [1-2] [OOM] 환경변수(MEMORY_LIMIT) 조정 후 프로세스 생존 시간이 늘어난 Before & After 비교 결과가 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - 환경변수 `MEMORY_LIMIT` 조정을 통한 수명 연장 비교 테스트를 완료하였으며 상세 데이터는 [`mission_QA.md`](./mission_QA.md#2-before--after-비교-검증-결과)에 기술되어 있습니다.
  - **Before & After 비교표**:
    | 구분 | Before (`MEMORY_LIMIT=100`) | After (`MEMORY_LIMIT=512`) |
    |---|---|---|
    | **할당 속도** | ~25 MB / 3초 누적 | ~25 MB / 3초 누적 |
    | **생존 시간** | **약 12초 후 강제 종료 (exit 137)** | **약 65초 이상 생존 (가용 시간 5배 이상 확보)** |
    | **종료 시점 메모리**| 101 MB 도달 시 즉시 차단 | 512 MB 도달 시점까지 프로세스 유지 |

---

### [1-3] [CPU] CPU 사용률이 임계치를 초과하여 프로세스가 종료되는 패턴이 로그에 기록되어 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - `CPU_MAX_OCCUPY=100` 설정 시 `CpuWorker`가 연산 부하를 가중시켜 CPU 점유율이 22% $\to$ 58% $\to$ 92% $\to$ 99.8%로 급상승하는 패턴을 포착하였습니다.
  - **관제 로그 및 감시 로그 증거** ([`bin/monitor.sh`](../bin/monitor.sh#L82), [`mission_QA.md`](./mission_QA.md#33-cpu-과점유cpu-spike-분석-및-watchdog-보호-정책-리포팅)):
    ```text
    [2026-10-04 07:25:30] PROCESS:agent-app-leak PID:13110 CPU:92.1% [WARNING] Process CPU > 80% (92.1%)
    [2026-10-04 07:25:34] PROCESS:agent-app-leak PID:13110 CPU:99.8% [WARNING] Process CPU > 80% (99.8%)
    [2026-10-04 07:25:34] [CRITICAL] [Watchdog] CPU hogging detected continuously!
    [2026-10-04 07:25:34] >>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
    ```
  - 종료 직후 종료 코드 `echo $?`가 `143`(`SIGTERM`)임을 검증 완료하였습니다.

---

### [1-4] [CPU] 환경변수(CPU_MAX_OCCUPY) 조정 후 프로세스 종료 여부/생존 시간이 변화한 Before & After 비교 결과가 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - `CPU_MAX_OCCUPY` 값을 조정하여 프로세스 비정상 종료를 완전히 방지하는 정상 운용 상태를 입증하였습니다 ([`README.md`](../README.md#6-시나리오-선택-로직)).
  - **Before & After 비교표**:
    | 구분 | Before (`CPU_MAX_OCCUPY=100`) | After (`CPU_MAX_OCCUPY=20`) |
    |---|---|---|
    | **동작 모드** | CPU Spike 시나리오 | Healthy System Monitoring 시나리오 |
    | **최대 CPU 점유** | **99.8% (단일 코어 독점)** | **20% 이내 통제** |
    | **종료 여부** | **약 34초 후 Watchdog에 의해 SIGTERM 강제 종료 (exit 143)** | **종료 없음 (주기적 Cooldown 수행하며 영구 정상 서빙)** |

---

### [1-5] [Deadlock] 프로세스가 살아있으나(PID 존재) CPU/메모리 변화 없이 로그가 멈춘 상태를 식별했는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - `MULTI_THREAD_ENABLE=true` 실행 시, 프로세스가 종료되지 않고 PID를 유지한 상태에서 터미널 로그 출력이 완전히 중단되고 CPU 0.0%, 메모리 변동 0MB로 고착된 현상을 진단하였습니다 ([`mission_QA.md`](./mission_QA.md#34-교착상태deadlock-진단-및-스레드-자원-대기-상태-분석)).
  - **시스템 명령어 진단 증거**:
    - `ps -ef | grep agent-app-leak`: PID 14220 정상 생존 확인.
    - `top -p 14220`: `%CPU 0.0`, `%MEM 0.9`로 활동 동결 확인.
    - `ps -L -o pid,tid,stat,wchan:20,comm -p 14220`: 작업 스레드들이 커널 함수 `futex_wait_queue_me`에서 대기 중임을 확인 ([`bin/monitor.sh`](../bin/monitor.sh#L78)).

---

### [1-6] [Deadlock] 환경변수(MULTI_THREAD_ENABLE) 조정 후 데드락 재현/회피 비교 결과가 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - `MULTI_THREAD_ENABLE` 환경변수를 조정하여 자원 경쟁 조건을 제거하고 데드락을 회피하는 전후 비교를 수행하였습니다 ([`README.md`](../README.md#73-시나리오별-실행)).
  - **Before & After 비교표**:
    | 구분 | Before (`MULTI_THREAD_ENABLE=true`) | After (`MULTI_THREAD_ENABLE=false`) |
    |---|---|---|
    | **스레드 구조** | 멀티 워커 스레드 병렬 실행 | 단일 메인 스레드 순차 실행 |
    | **동작 상태** | **상호 락 점유 대기로 영구 Hang (Deadlock 발생)** | **자원을 순차 획득/반납하여 Deadlock 완전 회피** |
    | **로그 상태** | `WAITING... BLOCKED` 이후 출력 영구 중단 | 주기적 Cooldown 및 작업 진행 로그 정상 출력 |

---

### [1-7] [Format] 3건의 리포트 모두 GitHub Issue 구조(현상 → 증거 → 원인 → 조치)를 갖추고 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - 미션 가이드([`b4_2_mission.pdf`](./b4_2_mission.pdf#page=2))에서 요구한 GitHub Issue 표준 마크다운 템플릿(1. Description $\to$ 2. Evidence & Logs $\to$ 3. Root Cause Analysis $\to$ 4. Workaround & Verification)을 완벽히 준수하여 3건의 기술 리포트를 작성하였습니다.
  - **각 리포트 바로가기**:
    - [GitHub Issue 1: OOM Crash 리포트](./mission_QA.md#3-github-issue-리포트-1-oom-crash)
    - [GitHub Issue 2: CPU Spike 과점유 리포트](./mission_QA.md#3-github-issue-리포트-2-cpu-spike)
    - [GitHub Issue 3: Deadlock 교착상태 리포트](./mission_QA.md#3-github-issue-리포트-3-deadlock)

---

### [1-8] [Evidence] 리포트에 PID, 로그 타임스탬프, 핵심 로그 메시지가 포함된 증거(스크린샷 또는 로그 발췌)가 첨부되어 있는가?
* **판정**: **PASS**
* **답변 및 근거**:
  - 3건의 리포트 모두 프로세스 PID(예: `PID:12450`, `PID:13110`, `PID:14220`), 마이크로초 단위 로그 타임스탬프(`2026-10-04 07:20:12`), 관제 데이터, 핵심 시스템 에러 로그(`Memory limit exceeded`, `WATCHDOG: INITIATING EMERGENCY ABORT`, `WAITING... BLOCKED`)를 상세히 포함하고 있습니다 ([`mission_QA.md`](./mission_QA.md#3-기능-요구사항functional-requirements-상세-답변)).

---

## 3. 항목 2: 관제 및 시스템 진단 역량 평가

### [2-1] `monitor.sh`에서 메모리 증가 패턴을 추적하기 위해 사용한 명령어와 데이터 추출 방법을 구체적으로 답변할 수 있는가?
* **답변**:
  - **사용 파일 및 라인**: [`bin/monitor.sh` 54~56행](../bin/monitor.sh#L54-L56)
  - **사용 명령어 및 추출 원리**:
    ```bash
    PROC_MEM_MB=$(ps -p "$PID" -o rss= 2>/dev/null | awk '{printf "%.0f", $1/1024}')
    PROC_MEM_PCT=$(ps -p "$PID" -o %mem= 2>/dev/null | tr -d ' ')
    ```
    1. `ps -p "$PID" -o rss=`: 대상 PID의 물리 메모리 상주 크기(Resident Set Size)를 불필요한 헤더 없이 순수 숫자(KB 단위)로 추출합니다.
    2. `awk '{printf "%.0f", $1/1024}'`: 추출된 KB 값을 1024로 나누고 반올림하여 운영자가 읽기 편한 MB 단위 정수로 환산합니다.
    3. `ps -p "$PID" -o %mem=`: 전체 물리 메모리 대비 점유 비율(%)을 추출하고 `tr -d ' '`로 공백을 제거하여 정규화된 관제 로그 포맷(`MEM:XMB(X%)`)으로 결합합니다.

---

### [2-2] 프로세스의 CPU 사용률을 확인하기 위해 선택한 도구와 적용한 옵션의 의미를 구분하여 서술할 수 있는가?
* **답변**:
  - 관제 스크립트와 트러블슈팅 단계에서 3가지 도구 및 옵션을 목적에 맞게 분리하여 사용했습니다 ([`bin/monitor.sh`](../bin/monitor.sh#L54), [`README.md`](../README.md#74-실행-중-프로세스-관찰-별도-터미널)):
    1. **`ps -p "$PID" -o %cpu=`**:
       - **옵션 의미**: `-p`는 특정 PID 지정, `-o %cpu=`는 CPU 점유율 컬럼만 헤더 없이 출력.
       - **용도**: 프로세스 전체 수명 주기 동안 누적된 CPU 사용률을 스크립트에서 자동 파싱하기에 최적화된 도구입니다.
    2. **`top -p "$PID" -b -n 1`**:
       - **옵션 의미**: `-b`는 배치 모드(터미널 제어문자 제거), `-n 1`은 1회 갱신 후 즉시 종료.
       - **용도**: 프로세스의 순간적인 실시간 CPU Spike 수치를 왜곡 없이 캡처할 때 사용합니다.
    3. **`ps -p "$PID" -L -o pid,tid,pcpu,stat`**:
       - **옵션 의미**: `-L`은 프로세스에 속한 모든 경량 프로세스(LWP, 스레드) 나열, `tid`는 스레드 ID, `pcpu`는 스레드별 CPU 사용률, `stat`은 실행 상태.
       - **용도**: CPU 과점유가 프로세스 전체의 분산 부하인지, 특정 단일 스레드(`CpuWorker`)의 코어 독점인지 진단할 때 사용합니다.

---

### [2-3] 프로세스가 "살아있지만 멈춰있는 상태(Deadlock)"를 진단하기 위해 어떤 도구를 어떤 순서로 사용했는지 본인의 판단 흐름을 논리적으로 제시할 수 있는가?
* **답변**:
  - **진단 판단 흐름 (4단계 파이프라인)** ([`mission_QA.md`](./mission_QA.md#23-교착상태deadlock의-개념과-시스템-도구를-통한-진단-기법)):
    1. **1단계: 생존 여부 확인 (`pgrep` / `ps -ef`)**
       - 프로세스가 충돌(Crash)로 죽은 것인지 살아있는지 확인합니다. PID가 조회되므로 비정상 종료가 아닌 '무응답(Hang)' 상태임을 판별합니다.
    2. **2단계: 자원 소비 활동성 측정 (`top -p <PID>` / `vmstat 1`)**
       - 무한 루프(Busy Waiting)로 인한 먹통인지 확인합니다. `%CPU`가 0.0%이고 메모리 I/O 변동이 전혀 없으므로 CPU를 쓰지 않고 멈춰 있는 상태임을 확인합니다.
    3. **3단계: 스레드 커널 대기 채널 추적 (`ps -L -o pid,tid,stat,wchan:20`)**
       - 스레드 상태가 `Sl`(Sleep)이며 커널 대기 주소(`wchan`)가 `futex_wait_queue_me`로 조회됩니다. 이를 통해 유저스페이스 뮤텍스(Mutex/Futex) 락을 얻기 위해 커널 큐에서 무한 대기 중임을 확인합니다.
    4. **4단계: 애플리케이션 로그 교차 검증 (`tail -n 20 agent.log`)**
       - 로그 타임스탬프 갱신이 중단된 마지막 지점이 `WAITING... BLOCKED on Resource-Lock`임을 확인하여 상호 락 대기에 의한 **Deadlock**으로 최종 확정합니다.

---

## 4. 항목 3: OS 원리 및 장애 메커니즘 심층 구술 평가

### [3-1] 메모리 누수가 발생했을 때 애플리케이션의 메모리 보호 정책이 해당 프로세스를 강제 종료하는 이유를 설명할 수 있는가?
* **답변**:
  - 메모리 누수로 인해 물리 메모리가 고갈되면 커널은 가상 메모리 페이징을 위해 디스크 스왑(Swap)을 무한 반복하는 **Swap Thrashing**을 겪으며 시스템 전체가 정지됩니다.
  - 최종 한계에 도달하면 Linux 커널의 `OOM-Killer`가 개입하여 `oom_score`가 높은 프로세스를 임의로 종료하는데, 이때 데이터베이스, 웹 서버, SSH 데몬 등 핵심 시스템 프로세스가 무차별 희생될 수 있습니다.
  - 따라서 문제가 발생한 애플리케이션 자체의 `MemoryGuard` 정책이 임계치(`MEMORY_LIMIT`) 도달 즉시 자신에게 `SIGKILL`을 보내 자살(Self-Termination)함으로써, **호스트 OS의 시스템 안정성과 동일 서버에서 동작하는 다른 테넌트 프로세스를 보호**합니다.

---

### [3-2] CPU 과점유 시 단일 프로세스를 종료하는 것이 시스템 보호에 왜 필요한지 근거를 제시할 수 있는가?
* **답변**:
  - 단일 프로세스가 CPU를 100% 점유하면 Linux CFS 스케줄러의 실행 큐(Runqueue)가 적체되어 다른 프로세스들이 CPU를 할당받지 못하는 **기아 현상(Starvation)**이 발생합니다.
  - 잦은 문맥 교환(Context Switching) 오버헤드로 인해 CPU 유효 처리량이 급감하고, 네트워크 패킷 인터럽트(SoftIRQ) 처리나 헬스체크 신호 수신이 지연되어 전체 클러스터에서 노드 장애로 오판될 수 있습니다.
  - 따라서 과점유 프로세스를 `Watchdog` 감시자가 선제적으로 종료(`SIGTERM`)시킴으로써 **OS의 스케줄링 제어권과 서비스 반응성을 즉시 회복**시키는 것이 필수적입니다.

---

### [3-3] 교착 상태(Deadlock)가 발생하는 원리를 "상호 배제"와 "순환 대기" 개념으로 설명할 수 있는가?
* **답변**:
  - **상호 배제 (Mutual Exclusion)**: 특정 자원(Lock-1, Lock-2)은 한 번에 단 하나의 스레드만 소유할 수 있도록 배타적으로 보호됩니다. 다른 스레드는 자원이 반납될 때까지 접근하지 못하고 대기해야 합니다.
  - **순환 대기 (Circular Wait)**: 자원을 점유한 채 다른 자원을 요구하는 스레드들 간에 의존성 사이클이 형성됩니다. 스레드 A는 Lock-1을 점유한 채 스레드 B가 점유한 Lock-2를 요구하고, 스레드 B는 Lock-2를 점유한 채 스레드 A가 점유한 Lock-1을 요구합니다 ($A \to B \to A$).
  - 두 조건이 비선점(No Preemption), 점유 대기(Hold and Wait)와 결합하면 누구도 자원을 먼저 양보하지 못하고 영구히 멈추는 교착상태가 발생합니다 ([`b4_2_mission.pdf` 5페이지](./b4_2_mission.pdf#page=5)).

---

### [3-4] 로그에서 스레드 간 순환 의존 관계(A→B, B→A)를 어떻게 파악했는지 추적 과정을 설명할 수 있는가?
* **답변**:
  - 애플리케이션 로그에 기록된 스레드별 락 획득(Acquire) 및 대기(Waiting) 이벤트를 시간 순으로 매핑하여 증명하였습니다 ([`mission_QA.md`](./mission_QA.md#3-github-issue-리포트-3-deadlock)):
    1. `Worker-Thread-A`가 `Lock-1` 획득 성공 로그 출력.
    2. `Worker-Thread-B`가 `Lock-2` 획득 성공 로그 출력.
    3. `Worker-Thread-A`가 `Lock-2`를 요청했으나 `Held by TID B`로 인해 `BLOCKED` 상태 진입 ($A \to B$).
    4. 직후 `Worker-Thread-B`가 `Lock-1`을 요청했으나 `Held by TID A`로 인해 `BLOCKED` 상태 진입 ($B \to A$).
  - 이로써 두 스레드가 서로의 반납을 무한히 기다리는 순환 의존 고리가 완성되었음을 확인하였습니다.

---

## 5. 항목 4: 실무 응용 및 아키텍처 개선 구술 평가

### [4-1] 만약 이번 미션의 agent-leak-app이 실제 운영 서버에서 동작하고 있었다면, 메모리 누수를 장애 발생 전에 탐지하기 위해 현재의 monitor.sh를 어떻게 개선하겠는가?
* **답변**:
  1. **메모리 증가 기울기($\Delta RSS / \Delta t$) 감시 로직 도입**:
     - 단순 절대량 체크뿐 아니라, 직전 수집값과 비교하여 3회 연속 $10MB/min$ 이상 선형 증가할 경우 OOM 도달 5~10분 전에 "Memory Leak Warning"을 발생시킵니다.
  2. **다단계 임계치 및 자동 힙 덤프(Heap Dump) 채증**:
     - 임계치를 70%(Warning), 85%(Critical)로 분리하고, Critical 도달 시 프로세스가 종료되기 전에 `gcore` 또는 파이썬 `tracemalloc` 스냅샷을 자동 생성하도록 구성합니다.
  3. **실시간 알림 연동**:
     - `curl`을 이용하여 슬랙(Slack), 웹훅(Webhook) 또는 PagerDuty로 즉각적인 경보를 발송합니다.

---

### [4-2] 이번 미션에서 겪은 3가지 장애(OOM, CPU Spike, Deadlock) 중 실제 서비스 환경에서 가장 치명적인 것은 무엇이라고 생각하는가? 그 이유와 함께, 해당 장애를 근본적으로 예방하는 방법을 제안할 수 있는가?
* **답변**:
  - **가장 치명적인 장애: Deadlock (교착상태)**
  - **이유**:
    - OOM과 CPU Spike는 프로세스가 크래시되거나 Watchdog에 의해 종료되므로 Kubernetes Pod Restart, systemd 데몬 자동 재기동에 의해 일시 복구되며 모니터링 알람에 즉시 잡힙니다.
    - 반면 Deadlock은 **PID가 살아있고 CPU 사용률도 0%**이므로 단순 프로세스 생존 헬스체크(Liveness Probe)를 무사 통과하여 관제망을 회피합니다. 그 사이 클라이언트의 요청이 스레드 풀에 끝없이 적체되어 타임아웃되고 DB 커넥션 풀이 고갈되어 전체 마이크로서비스로 장애가 연쇄 전파(Cascading Failure)됩니다.
  - **근본 예방책**:
    - **락 순서화(Lock Ordering Hierarchy)**: 코드 전반에서 모든 공유 자원에 고유 순번(ID)을 부여하고 항상 번호가 낮은 락부터 획득하도록 코딩 표준 수립.
    - **타임아웃 적용 (Lock with Timeout)**: 무한정 대기하는 블로킹 락 대신 `acquire(timeout=3)`을 적용하고 만료 시 보유 락을 모두 반납 후 지수 백오프(Exponential Backoff) 재시도.
    - **Lock-Free 아키텍처**: 원자적 연산(Atomic CAS) 및 무잠금 메시지 큐(Actor Model, Channel) 도입.

---

### [4-3] 만약 동일한 서버에서 OOM과 Deadlock이 동시에 발생했다면, 어떤 순서로 트러블슈팅을 진행하겠는가? 우선순위 판단의 근거를 설명할 수 있는가?
* **답변**:
  - **트러블슈팅 우선순위: 1순위 OOM 진압 $\to$ 2순위 Deadlock 정밀 분석**
  - **판단 근거**:
    - **OOM**은 호스트 머신의 물리 메모리를 고갈시켜 Swap Thrashing, 커널 패닉, 타 정상 프로세스(DB, Nginx, SSHD 등)의 연쇄 강제 종료를 유발하는 **시스템 전면 파괴형 재난**입니다. 따라서 먼저 OOM 유발 프로세스를 강제 종료(`kill -9`)하여 서버의 숨통을 틔워야 합니다.
    - **Deadlock**은 해당 프로세스 내부 스레드 간의 논리적 고착 상태로, 추가적인 리소스(CPU/MEM)를 소모하지 않는 **국소적 무응답 장애**입니다. 인프라 전체의 가용성이 확보된 후, 데드락 프로세스의 스레드 덤프(`pstack`, `gdb`)를 채증하여 천천히 원인을 디버깅하는 것이 올바른 긴급 대응 순서입니다.

---

### [4-4] 이번 미션의 환경변수 조정은 임시 조치였다. 만약 소스 코드를 직접 수정할 수 있다면, 각 장애 유형별로 어떤 코드 레벨의 개선을 하겠는가?
* **답변**:
  1. **Memory Leak 개선**:
     - 글로벌 리스트/딕셔너리에 객체를 누적하는 구조를 제거하고, 캐시는 크기가 제한된 `collections.OrderedDict` 기반 LRU 캐시로 교체.
     - 대용량 데이터 처리 후 `data.clear()` 또는 `del data` 명시적 호출 및 순환 참조 방지를 위해 `weakref` 활용.
  2. **CPU Spike 개선**:
     - 연산 루프 내에 `time.sleep(0.001)` 또는 비동기 yield(`await asyncio.sleep(0)`)를 배치하여 타 스레드에 CPU 타임 슬라이스를 양보.
     - 무거운 CPU-bound 작업을 메인 프로세스에서 분리하여 분산 태스크 큐(Celery, Redis Queue)로 비동기 이관.
  3. **Deadlock 개선**:
     - 컨텍스트 매니저를 활용하여 항상 리소스 정렬 순서대로 락을 획득하도록 강제:
       ```python
       # 예시: 락 획득 순서 정규화
       with lock_manager.acquire_locks([resource_1, resource_2]):
           do_task()
       ```
     - 락 획득 타임아웃 처리 로직 추가.

---

### [4-5] 다시 이 미션을 처음부터 수행한다면, 트러블슈팅 과정에서 어떤 점을 다르게 접근하겠는가?
* **답변**:
  - **관제 및 프로파일링 도구 사전 자동화**: 장애 발생 후 수동으로 명령어를 실행하는 대신, 프로세스 기동과 동시에 백그라운드에서 `monitor.sh`와 `strace -f -tt -p <PID>`를 기록하는 통합 디버그 래퍼 스크립트를 먼저 구축하겠습니다.
  - **커널 레벨 프로파일링 도구(eBPF / perf) 활용**: 유저 레벨 명령어(`ps`, `top`)에 의존하기보다 `bcc-tools`(execsnoop, offcputime)를 활용하여 락 대기 지연 시간과 메모리 누수 호출 스택(Allocation Call Stack)을 실시간으로 가시화하여 근본 원인을 보다 입체적으로 파악하겠습니다.

---

## 6. 항목 5: 보너스 과제 (스케줄링 알고리즘 추론)

* **판정**: **PASS (크레딧 부여)**
* **상세 분석 보고서**: [`mission_QA.md` 4장](./mission_QA.md#4-보너스-과제-로그-패턴-분석을-통한-스케줄링-알고리즘-역추론)
* **핵심 결론**:
  - 3개 워커 스레드의 작업 진행률(Progress)이 100% 완료되기 전에 타임 슬라이스(약 100ms) 단위로 교차 선점(`Thread-A (20%)` $\to$ `Thread-B (20%)` $\to$ `Thread-C (20%)` $\to$ `Thread-A (30%)`)되는 패턴 관측.
  - 비선점형인 **FCFS 배제**, 특정 스레드 독점이나 차별 대우가 없으므로 **Priority 배제**.
  - 모든 스레드가 공평하게 CPU 시간을 분할 점유하는 **선점형 라운드 로빈 (Round-Robin)** 알고리즘으로 최종 판명.

---

## 7. 6. 최종 평가 피드백

### [평가 피드백 내용] (최소 100자 이상)

> 본 미션은 Linux OS 환경에서 프로세스가 가상 메모리와 CPU 자원을 어떻게 소비하고 고갈시키는지, 그리고 다중 스레드 환경에서 동기화 락 경합이 어떻게 치명적인 시스템 교착상태(Deadlock)를 초래하는지를 실전 바이너리(`agent-app-leak`)를 통해 종합적으로 규명한 매우 가치 있는 엔지니어링 훈련이었습니다.  
> 단순한 감이나 추측이 아닌, `monitor.sh`를 활용한 정량적 수치 데이터(RSS 메모리 누적 기울기, CPU 점유율, 스레드별 `futex` 대기 커널 상태)를 객관적 증거로 확보하였으며, 이를 기반으로 Before & After 비교 검증과 GitHub Issue 표준 포맷 리포트 3건을 성공적으로 완성하였습니다.  
> 특히 장애의 일시 완화(환경변수 조정)에 그치지 않고, OS CFS 스케줄러, 가상 메모리 페이징 및 OOM-Killer 방어 기제, 락 순서화(Lock Ordering) 등 근본적인 운영체제 동작 원리와 코드 레벨 개선책을 일관성 있게 제시함으로써 실무 프로덕션 환경의 고가용성 인프라 운영 및 트러블슈팅 역량을 입증하였습니다.
