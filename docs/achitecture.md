# 시스템 아키텍처 및 내부 메커니즘 분석서 (`architecture.md`)

> **대상 프로젝트**: Linux 프로세스 및 시스템 리소스 트러블슈팅 (`codyssey-b4-2`)  
> **핵심 바이너리**: [`agent-app-leak`](../agent-app-leak)  
> **관제 스크립트**: [`bin/monitor.sh`](../bin/monitor.sh)  
> **문서 목적**: 시스템 전체 계층 구조, 바이너리 내부 동작 루프, 부트 시퀀스, 시나리오 라우팅 로직, OS 커널과의 상호작용 및 관제 파이프라인을 다이어그램(Mermaid)과 함께 시각화하여 설명함.

---

## 목차
1. [시스템 전체 아키텍처](#1-시스템-전체-아키텍처)
2. [컴포넌트별 상세 설계](#2-컴포넌트별-상세-설계)
   - 2.1 [애플리케이션 계층 (`agent-app-leak`)](#21-애플리케이션-계층-agent-app-leak)
   - 2.2 [관제 및 모니터링 계층 (`monitor.sh`)](#22-관제-및-모니터링-계층-monitorsh)
   - 2.3 [운영체제 및 런타임 계층](#23-운영체제-및-런타임-계층)
3. [부트 시퀀스 및 환경 검증 흐름도](#3-부트-시퀀스-및-환경-검증-흐름도)
4. [시나리오 라우팅 및 장애 트리거 로직](#4-시나리오-라우팅-및-장애-트리거-로직)
5. [장애 유형별 내부 동작 시퀀스](#5-장애-유형별-내부-동작-시퀀스)
   - 5.1 [OOM & MemoryGuard 시퀀스](#51-oom--memoryguard-시퀀스)
   - 5.2 [CPU Spike & Watchdog 시퀀스](#52-cpu-spike--watchdog-시퀀스)
   - 5.3 [Deadlock & 순환 락 대기 상태도](#53-deadlock--순환-락-대기-상태도)
6. [관제 스크립트(`monitor.sh`) 데이터 수집 파이프라인](#6-관제-스크립트monitorsh-데이터-수집-파이프라인)

---

## 1. 시스템 전체 아키텍처

본 시스템은 Docker 컨테이너 환경의 격리된 Linux OS 위에서 실행되며, 일반 사용자 계정(`agent-admin`) 하에서 기동되는 대상 애플리케이션(`agent-app-leak`), 실시간 리소스 관제 스크립트(`bin/monitor.sh`), 그리고 cron 주기적 스케줄러로 구성됩니다.

```mermaid
flowchart TB
    subgraph Host["Host Environment (Windows / macOS)"]
        subgraph Docker["Docker Container (Ubuntu 24.04 LTS)"]
            subgraph UserSpace["User Space (agent-admin)"]
                subgraph App["Target Binary: agent-app-leak"]
                    Boot["Boot Sequence\n(1~6 Checks)"]
                    Router["Scenario Router\n(Env Dispatcher)"]
                    subgraph Workers["Worker Subsystems"]
                        MW["MemoryWorker\n(Heap Leak)"]
                        CW["CpuWorker\n(CPU Hogging)"]
                        DW["DeadlockWorker\n(Circular Lock)"]
                        HW["HealthyWorker\n(Cooldown Loop)"]
                    end
                    subgraph Guards["Self-Protection Guards"]
                        MG["MemoryGuard\n(Threshold Check)"]
                        WD["Watchdog\n(Spike Check)"]
                    end
                end

                subgraph MonitorSystem["Monitoring Subsystem"]
                    Cron["Crontab (매 1분)"] --> Script["bin/monitor.sh"]
                    Manual["수동 실행"] --> Script
                    Script --> Health["Health Check (PID, Port)"]
                    Script --> Resource["Resource Collector (ps, awk, df)"]
                    Script --> ThreadInfo["Thread Inspector (ps -L)"]
                    Script --> LogRotate["Log Rotator (Max 10MB x 10)"]
                end

                subgraph Storage["File System & Storage"]
                    KeyFile["$AGENT_KEY_PATH/secret.key"]
                    UploadDir["$AGENT_UPLOAD_DIR"]
                    LogDir["$AGENT_LOG_DIR/monitor.log"]
                end
            end

            subgraph KernelSpace["Linux Kernel Space"]
                CFS["CFS Scheduler\n(Runqueue & vruntime)"]
                VM["Virtual Memory\n(Page Cache & RSS)"]
                Futex["Futex Subsystem\n(Mutex Wait Queue)"]
                OOMK["OS OOM-Killer\n(oom_score)"]
            end
        end
    end

    Boot --> KeyFile
    Boot --> UploadDir
    Router --> MW & CW & DW & HW
    MW -.->|Memory Surge| MG
    CW -.->|CPU Spike| WD
    DW -.->|Mutex Lock| Futex
    MG -->|SIGKILL 137| App
    WD -->|SIGTERM 143| App
    Resource --> VM
    Resource --> CFS
    Script --> LogDir
```

---

## 2. 컴포넌트별 상세 설계

### 2.1 애플리케이션 계층 (`agent-app-leak`)
* **언어 및 런타임**: Python 기반 로직이 번들링된 64-bit Linux ELF 바이너리.
* **보안 및 실행 제약**: `root` 계정 실행 원천 차단 (일반 계정 강제).
* **주요 내부 모듈**:
  - **Boot Sequence Engine**: 6단계 사전 환경(사용자, 환경변수, 파일, 포트, 쓰기 권한, 파라미터 유효 범위) 검증.
  - **Scenario Dispatcher**: 환경변수(`MEMORY_LIMIT`, `CPU_MAX_OCCUPY`, `MULTI_THREAD_ENABLE`) 조합에 따라 장애 시뮬레이션 분기.
  - **MemoryWorker**: 3초마다 25MB의 더미 버퍼를 전역 메모리에 할당하여 힙 누수 유발.
  - **CpuWorker**: 부하 단계를 순차적으로 상승시켜 단일 코어를 100% 점유.
  - **DeadlockWorker**: Worker-A와 Worker-B 간의 교차 락 획득(`Resource-1`, `Resource-2`)을 통한 순환 대기 형성.
  - **MemoryGuard**: 프로세스 자체 물리 메모리(RSS)가 임계치 도달 시 커널 OOM-Killer 개입 전에 `SIGKILL` 자살 실행.
  - **Watchdog**: CPU 과점유가 지속될 경우 시스템 전면 마비를 방지하기 위해 `SIGTERM` 비상 중단 발행.

### 2.2 관제 및 모니터링 계층 (`monitor.sh`)
* **위치**: [`bin/monitor.sh`](../bin/monitor.sh)
* **주요 기능**:
  - **프로세스 생존 감시**: `pgrep -f agent-app-leak`을 통한 PID 조회.
  - **네트워크 바인딩 감시**: `ss -tulnp` 명령어를 통한 `15034` 포트 리스닝 상태 확인.
  - **정밀 리소스 수집**:
    - CPU: `ps -p $PID -o %cpu=`
    - 메모리(MB): `ps -p $PID -o rss=` 파싱 및 `awk` 1024 환산
    - 메모리 점유율(%): `ps -p $PID -o %mem=`
    - 디스크: `df /` 잔여 용량(GB) 및 점유율(%)
    - 방화벽: `ufw status` 활성화 여부
  - **스레드 레벨 세부 진단**: `ps -p $PID -L`로 스레드 수 및 각 TID별 상태(`STAT`), CPU, 커널 대기 채널(`wchan`) 추적 (Deadlock 포착용).
  - **임계치 경고 엔진**: CPU > 80%, 메모리 점유율 > 30%, 디스크 > 80% 시 `[WARNING]` 태그 출력.
  - **로그 로테이션(Log Rotation)**: 10MB 초과 시 최대 10개 파일(`monitor.log.1` ~ `monitor.log.10`) 순환 보관.

### 2.3 운영체제 및 런타임 계층
* **가상 메모리 관리자**: 물리 메모리(RSS)와 가상 메모리(VIRT) 매핑, 페이지 폴트(Page Fault) 처리 및 스왑(Swap) 제어.
* **CFS CPU 스케줄러**: 프로세스 및 스레드의 `vruntime`을 추적하여 멀티태스킹 실행 큐 관리.
* **Futex (Fast Userspace Mutex)**: 멀티스레드 락 경합 시 유저 공간 확인 후 대기 스레드를 커널 슬립 큐에 등록.

---

## 3. 부트 시퀀스 및 환경 검증 흐름도

바이너리 기동 시 순차적으로 수행되는 6단계 엄격한 검증 로직입니다.

```mermaid
flowchart TD
    Start(["바이너리 실행 ($AGENT_HOME/agent-app-leak)"]) --> Step1{"[1/6] User Account Check\nroot 여부 확인"}
    Step1 -- root 계정 --> Fail1["[FAIL] Running as 'root' is forbidden\n(Exit 1)"]
    Step1 -- 일반 사용자 (agent-admin) --> Step2{"[2/6] Environment Variables\n필수 환경변수 선언 확인"}

    Step2 -- 누락 또는 오설정 --> Fail2["[FAIL] Missing required envs\n(Exit 1)"]
    Step2 -- AGENT_HOME 등 정상 --> Step3{"[3/6] Required Files\nsecret.key 내용 및 경로"}

    Step3 -- 파일 부재 또는 내용 불일치 --> Fail3["[FAIL] secret.key verification failed\n(Exit 1)"]
    Step3 -- 일치 (agent_api_key_test) --> Step4{"[4/6] Port Availability\n15034 바인딩 가능 여부"}

    Step4 -- 이미 점유됨 --> Fail4["[FAIL] Port 15034 unavailable\n(Exit 1)"]
    Step4 -- 포트 가용 --> Step5{"[5/6] Log Permission\n/var/log/agent-app 쓰기 가능"}

    Step5 -- 쓰기 권한 없음 --> Fail5["[FAIL] Log dir not writable\n(Exit 1)"]
    Step5 -- 쓰기 권한 정상 --> Step6{"[6/6] Mission Environment\nMEMORY_LIMIT, CPU_MAX_OCCUPY"}

    Step6 -- 유효 범위 초과 --> Fail6["[FAIL] Invalid parameter range\n(Exit 1)"]
    Step6 -- 정상 범위 (50~512, 10~100) --> Success(["All Boot Checks Passed!\nAgent READY"])
```

---

## 4. 시나리오 라우팅 및 장애 트리거 로직

환경변수 값의 조합에 따라 바이너리가 내부적으로 진입하는 4가지 시나리오 결정 트리입니다.

```mermaid
flowchart TD
    Ready(["Agent READY"]) --> CheckMem{"MEMORY_LIMIT < 256 ?"}
    
    CheckMem -- "Yes (< 256MB)\n예: 100MB" --> ScenOOM["OOM / Memory Leak Scenario\n- MemoryWorker 기동 (25MB/3s 할당)\n- MemoryGuard 활성화\n- 결과: 약 12초 후 SIGKILL (Exit 137)"]
    
    CheckMem -- "No (>= 256MB)\n예: 512MB" --> CheckCPU{"CPU_MAX_OCCUPY == 100\nAND MULTI_THREAD_ENABLE == false ?"}
    
    CheckCPU -- "Yes" --> ScenCPU["CPU Spike Scenario\n- CpuWorker 기동 (단계적 부하 상승)\n- Watchdog 활성화\n- 결과: 약 34초 후 SIGTERM (Exit 143)"]
    
    CheckCPU -- "No" --> CheckThread{"CPU_MAX_OCCUPY <= 20\nAND MULTI_THREAD_ENABLE == true ?"}
    
    CheckThread -- "Yes" --> ScenDeadlock["Deadlock Scenario\n- 멀티스레드 Worker A, B 기동\n- 교차 락 점유 시도 (Circular Wait)\n- 결과: 무응답 Hang (Futex 대기)"]
    
    CheckThread -- "No (MULTI_THREAD == false)" --> ScenHealthy["Healthy System Monitoring\n- 제어된 부하 및 주기적 Cooldown\n- 결과: 정상 무중단 실행 유지"]
```

---

## 5. 장애 유형별 내부 동작 시퀀스

### 5.1 OOM & MemoryGuard 시퀀스
메모리 누수 발생 시 애플리케이션 자체 방어 정책(`MemoryGuard`)이 시스템 전체 파괴를 방지하기 위해 개입하는 과정입니다.

```mermaid
sequenceDiagram
    autonumber
    actor Admin as agent-admin
    participant App as agent-app-leak
    participant MW as MemoryWorker
    participant MG as MemoryGuard
    participant OS as Linux Kernel
    participant Mon as monitor.sh

    Admin->>App: MEMORY_LIMIT=100 실행
    App->>MW: 워커 스레드 시작
    loop 매 3초마다
        MW->>MW: 25MB 버퍼 할당 및 리스트 저장
        Mon->>OS: ps -p $PID -o rss= 관제 수집
        OS-->>Mon: RSS 수치 반환 (26MB -> 51MB -> 76MB)
    end
    MW->>MW: 누적 메모리 101MB 도달
    MG->>OS: 현재 RSS 확인 (101MB >= 100MB)
    MG->>App: [CRITICAL] Memory limit exceeded!
    MG->>OS: kill(self, SIGKILL) 시스템 콜 호출
    OS-->>App: 강제 종료 (Exit Code 137)
    Mon->>App: pgrep 확인 -> Process Not Running 감지
```

---

### 5.2 CPU Spike & Watchdog 시퀀스
CPU 과점유 시 백그라운드 `Watchdog` 스레드가 시스템 반응성을 복구하기 위해 비상 중단을 수행하는 흐름입니다.

```mermaid
sequenceDiagram
    autonumber
    actor Admin as agent-admin
    participant App as agent-app-leak
    participant CW as CpuWorker
    participant WD as Watchdog
    participant CFS as Linux CFS Scheduler
    participant Mon as monitor.sh

    Admin->>App: CPU_MAX_OCCUPY=100 실행
    App->>CW: 연산 워커 가동
    CW->>CFS: 연산 부하 급증 (Runqueue 독점)
    Mon->>CFS: ps -p $PID -o %cpu= (92.1% -> 99.8%)
    Mon-->>Mon: [WARNING] Process CPU > 80%
    loop 과점유 감시 인터벌
        WD->>CFS: CPU 점유 지속 시간 계측
    end
    WD->>App: [CRITICAL] CPU hogging detected continuously!
    WD->>App: [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT
    WD->>App: raise(SIGTERM) 발행
    App-->>Admin: 프로세스 비상 종료 (Exit Code 143)
```

---

### 5.3 Deadlock & 순환 락 대기 상태도
멀티스레드 활성화 시 두 스레드가 교착상태에 진입하는 상태 전이 모델입니다.

```mermaid
stateDiagram-v2
    [*] --> Init: 멀티스레드 부트 완료

    state Worker_Thread_A {
        [*] --> A_Acquire_Lock1: Lock-1 요청
        A_Acquire_Lock1 --> A_Hold_Lock1: Lock-1 획득 (Hold)
        A_Hold_Lock1 --> A_Wait_Lock2: Lock-2 요청 (Wait)
    }

    state Worker_Thread_B {
        [*] --> B_Acquire_Lock2: Lock-2 요청
        B_Acquire_Lock2 --> B_Hold_Lock2: Lock-2 획득 (Hold)
        B_Hold_Lock2 --> B_Wait_Lock1: Lock-1 요청 (Wait)
    }

    A_Wait_Lock2 --> Deadlock_Blocked: TID B가 소유 중 -> Blocked
    B_Wait_Lock1 --> Deadlock_Blocked: TID A가 소유 중 -> Blocked

    state Deadlock_Blocked {
        description: "상호 배제 + 점유 대기 + 비선점 + 순환 대기 (A -> B -> A)"
        Kernel_State: futex_wait_queue_me (CPU 0.0%, MEM 정체)
    }

    Deadlock_Blocked --> [*]: 외부 SIGINT(Ctrl+C) 또는 SIGKILL 수동 개입 시에만 해제
```

---

## 6. 관제 스크립트(`monitor.sh`) 데이터 수집 파이프라인

단일 관제 실행 시 데이터가 처리되어 출력 및 저장되는 파이프라인입니다.

```mermaid
flowchart LR
    Start(["실행"]) --> Pgrep["pgrep -f\nPID 추출"]
    Pgrep --> Found{"PID 존재?"}
    
    Found -- "No" --> ExitFail["Process [FAIL]\n관제 중단 (Exit 1)"]
    Found -- "Yes" --> PortCheck["ss -tulnp\n15034 포트 점유 검사"]
    
    PortCheck --> ResCollect["리소스 수집\n- ps (CPU%, RSS KB)\n- awk (MB 환산)\n- df (디스크 잔여/사용률)\n- ufw (방화벽 상태)"]
    
    ResCollect --> ThreadCollect["스레드 진단\nps -L (TID, STAT, WCHAN)"]
    
    ThreadCollect --> WarnEval{"임계치 평가\nCPU > 80%?\nMEM > 30%?\nDISK > 80%?"}
    
    WarnEval --> RotateCheck{"monitor.log\n크기 > 10MB ?"}
    
    RotateCheck -- "Yes" --> DoRotate["로그 로테이션\n.1 ~ .10 순환 백업"]
    RotateCheck -- "No" --> AppendLog["로그 파일 추가 기록\n/var/log/agent-app/monitor.log"]
    DoRotate --> AppendLog
    AppendLog --> End(["터미널 요약 출력 완료"])
```
