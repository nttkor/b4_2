# 시스템 장애 분석 및 리소스 트러블슈팅 미션 Q&A 종합 보고서

> **대상 문서**: `b4_2_mission.pdf`  
> **대상 애플리케이션**: `agent-app-leak` (Linux 64-bit ELF)  
> **문서 목적**: 미션의 목표(Goal) 및 기능 요구사항(Functional Requirements)을 완벽히 분석하고, 각 항목에 대한 심층적 기술 답변과 장애 리포트(GitHub Issue)를 작성하여 제시함.

---

## 목차
1. [미션 개요](#1-미션-개요)
2. [미션 목표(Goals) 상세 답변](#2-미션-목표goals-상세-답변)
   - 2.1 [메모리 구조와 메모리 누수가 시스템 전체에 미치는 영향](#21-메모리-구조와-메모리-누수가-시스템-전체에-미치는-영향)
   - 2.2 [특정 프로세스의 CPU 과점유가 시스템 지연을 유발하는 원리](#22-특정-프로세스의-cpu-과점유가-시스템-지연을-유발하는-원리)
   - 2.3 [교착상태(Deadlock)의 개념과 시스템 도구를 통한 진단 기법](#23-교착상태deadlock의-개념과-시스템-도구를-통한-진단-기법)
   - 2.4 [로그/관제 데이터 기반 장애 기술 및 GitHub Issue 커뮤니케이션](#24-로그관제-데이터-기반-장애-기술-및-github-issue-커뮤니케이션)
3. [기능 요구사항(Functional Requirements) 상세 답변](#3-기능-요구사항functional-requirements-상세-답변)
   - 3.1 [사전 준비 사항 및 부트 시퀀스 6단계 검증](#31-사전-준비-사항-및-부트-시퀀스-6단계-검증)
   - 3.2 [메모리 누수(OOM Crash) 원인 규명 및 리포팅](#32-메모리-누수oom-crash-원인-규명-및-리포팅)
   - 3.3 [CPU 과점유(CPU Spike) 분석 및 Watchdog 보호 정책 리포팅](#33-cpu-과점유cpu-spike-분석-및-watchdog-보호-정책-리포팅)
   - 3.4 [교착상태(Deadlock) 진단 및 스레드 자원 대기 상태 분석](#34-교착상태deadlock-진단-및-스레드-자원-대기-상태-분석)
4. [보너스 과제: 로그 패턴 분석을 통한 스케줄링 알고리즘 역추론](#4-보너스-과제-로그-패턴-분석을-통한-스케줄링-알고리즘-역추론)
5. [시스템 평가 심화 Q&A (Eval 핵심 문항 연계)](#5-시스템-평가-심화-qa-eval-핵심-문항-연계)

---

## 1. 미션 개요

본 미션은 Linux 운영체제 환경에서 동작하는 서버 애플리케이션(`agent-app-leak`)의 3대 핵심 시스템 장애인 **OOM(Out Of Memory) Crash**, **CPU Spike(과점유)**, **Deadlock(교착상태)** 현상을 관제 도구(`monitor.sh`, `ps`, `top` 등)와 로그 데이터를 활용하여 과학적으로 진단하고, 환경변수를 통해 임시 완화(Workaround) 및 검증(Verification)을 수행한 뒤 협업 가능한 형태의 GitHub Issue 기술 리포트로 정리하는 실전 역량을 평가합니다.

---

## 2. 미션 목표(Goals) 상세 답변

### 2.1 메모리 구조와 메모리 누수가 시스템 전체에 미치는 영향

#### Q. 리눅스 프로세스의 메모리 구조는 어떻게 구성되며, 단일 프로세스의 메모리 누수가 시스템 전체에 어떤 파급 효과를 미치는가?
* **답변**:
  1. **프로세스 가상 메모리 공간(Virtual Memory Space) 구조**:
     - **Text (Code) 영역**: 실행 가능한 기계어 코드가 적재되는 읽기 전용(Read-Only) 영역입니다.
     - **Data / BSS 영역**: 전역 변수(Global Variable) 및 정적 변수(Static Variable)가 저장됩니다. Data는 초기화된 변수, BSS는 0으로 초기화되지 않은 변수가 할당됩니다.
     - **Heap 영역**: `malloc()`, `new` 또는 파이썬 객체 생성 등에 의해 런타임에 동적으로 할당되는 공간입니다. 낮은 주소에서 높은 주소 방향으로 자라납니다.
     - **Stack 영역**: 함수 호출 시의 지역 변수, 매개변수, 반환 주소(Return Address) 등이 임시로 저장되며, 높은 주소에서 낮은 주소 방향으로 자라납니다.
  2. **메모리 누수(Memory Leak)의 메커니즘**:
     - 힙(Heap) 영역에 객체나 버퍼를 동적으로 생성한 후, 참조가 해제되지 않거나 명시적으로 메모리를 반환(`free()`, `del`, GC 회수)하지 못하면 해당 메모리는 프로세스가 종료될 때까지 힙에 계속 누적됩니다.
  3. **시스템 전체에 미치는 파급 효과**:
     - **Page Cache 잠식**: 리눅스 커널은 파일 I/O 속도 향상을 위해 물리 메모리를 페이지 캐시로 적극 활용합니다. 하지만 프로세스가 물리 메모리(RSS)를 과도하게 점유하면 커널은 페이지 캐시를 강제로 축소시킵니다. 이로 인해 디스크 읽기/쓰기가 물리 I/O로 직접 전달되어 시스템 I/O 병목이 발생합니다.
     - **Swap Thrashing(스왑 쓰레싱)**: 가용 물리 메모리가 고갈되면 OS는 비활성 페이지를 디스크의 스왑(Swap) 영역으로 방출(Page Out)하고, 필요 시 다시 읽어들입니다(Page In). 디스크 I/O 속도는 DRAM에 비해 수천~수만 배 느리므로, CPU는 프로세스 작업 대신 페이지 교체 작업에 100% 소모되어 시스템 전체가 완전히 멈추는 쓰레싱 상태에 빠집니다.
     - **Linux 커널 OOM-Killer 강제 개입**: 시스템 메모리가 한계에 도달하면 커널은 `oom_score`가 높은 프로세스를 선정하여 `SIGKILL(9)`로 즉시 강제 종료합니다. 이때 문제의 원인 프로세스뿐만 아니라 핵심 데몬(SSH, DB, Nginx 등)이 무차별 희생될 위험이 발생합니다.
     - **MemoryGuard의 방어적 종료**: `agent-app-leak`의 경우, OS OOM-Killer에 의해 시스템 전체가 연쇄 다운되는 참사를 막기 위해 애플리케이션 내부에서 물리 메모리 사용량이 `MEMORY_LIMIT`에 도달하면 자체적으로 `SIGKILL`을 호출하여 자살(Self-Termination)하는 보호 아키텍처를 구현하고 있습니다.

---

### 2.2 특정 프로세스의 CPU 과점유가 시스템 지연을 유발하는 원리

#### Q. 단일 프로세스가 CPU를 100% 점유할 때, 왜 동일 서버에서 동작하는 다른 프로세스 및 시스템 전체가 지연(Latency)되는가?
* **답변**:
  1. **CPU 스케줄러(CFS - Completely Fair Scheduler)의 동작 한계**:
     - 리눅스 기본 스케줄러인 CFS는 `vruntime`(Virtual Runtime)을 기반으로 스레드 간 CPU 실행 시간을 공평하게 분배합니다.
     - 특정 프로세스가 끊임없이 무한 루프, 대규모 수학 연산, Busy Waiting을 수행하면 해당 코어의 실행 큐(Runqueue)가 비워지지 않고 항상 가득 차게 됩니다.
  2. **시스템 지연(System Latency) 유발 원리**:
     - **Runqueue 대기 시간 급증**: 코어 수 대비 실행 가능한 스레드 수(Load Average)가 급증하여, 일반 사용자 요청을 처리해야 할 다른 스레드가 CPU를 할당받지 못하고 실행 큐에서 오래 대기(Runqueue Latency)하게 됩니다.
     - **잦은 문맥 교환(Context Switching) 오버헤드**: 스케줄러는 공평성을 유지하기 위해 타임 슬라이스(Time Slice)마다 강제로 인터럽트를 걸어 문맥 교환을 발생시킵니다. 문맥 교환 시 CPU 레지스터 백업, TLB(Translation Lookaside Buffer) 플러시, L1/L2 CPU 캐시 무효화가 발생하여 CPU 유효 처리량이 급감합니다.
     - **커널 스케줄링 인터럽트 및 I/O 지연**: CPU 사용률이 100%에 육박하면 네트워크 패킷 인터럽트(SoftIRQ), 디스크 I/O 완료 콜백 처리가 제때 수행되지 못해 외부 HTTP/gRPC 요청에 대해 Timeout이 발생합니다.
  3. **Watchdog 정책의 필요성**:
     - 특정 프로세스가 의도치 않게 코어를 독점하면 시스템 전체의 서비스 가용성(High Availability)이 훼손됩니다.
     - 애플리케이션의 **Watchdog** 루틴은 CPU 과점유(`CPU_MAX_OCCUPY`)가 일정 시간 지속되는 것을 감지하면, 전체 서버 락업(Lockup)을 막기 위해 대상 워커 스레드나 프로세스에 `SIGTERM`을 발송하여 긴급 중단(Emergency Abort)을 수행합니다.

---

### 2.3 교착상태(Deadlock)의 개념과 시스템 도구를 통한 진단 기법

#### Q. 교착상태(Deadlock)란 무엇이며, 프로세스가 종료되지 않고 멈춰있는 상태를 시스템 명령어로 어떻게 식별하고 진단하는가?
* **답변**:
  1. **교착상태(Deadlock)의 개념 및 4대 필요조건**:
     - 둘 이상의 프로세스 또는 스레드가 서로가 점유하고 있는 자원의 락(Lock)을 획득하기 위해 무한히 대기하는 상태를 말합니다.
     - **Coffman의 4대 조건**:
       1. **상호 배제 (Mutual Exclusion)**: 한 번에 한 스레드만 공유 자원을 사용할 수 있음 (Mutex, Semaphore).
       2. **점유 대기 (Hold and Wait)**: 최소 하나의 자원을 점유한 채로, 다른 스레드가 점유한 자원을 추가로 요구하며 대기함.
       3. **비선점 (No Preemption)**: 다른 스레드가 보유한 자원을 강제로 빼앗을 수 없으며, 자발적으로 반납할 때까지 기다려야 함.
       4. **순환 대기 (Circular Wait)**: 대기하는 스레드들 간에 환형 체인이 형성됨 ($T_1 \to T_2 \to T_1$).
  2. **식사하는 철학자 문제(Dining Philosophers Problem) 모델**:
     - 원형 식탁에 앉은 철학자 5명이 각각 왼쪽 포크를 쥔 채(Hold), 오른쪽 포크가 비기를 기다리면(Wait), 아무도 식사를 하지 못하고 굶어 죽는 순환 대기 모델입니다.
     - `agent-app-leak`의 멀티스레드 모드(`MULTI_THREAD_ENABLE=true`)에서도 Worker A가 Resource-1을 점유한 채 Resource-2를 요청하고, Worker B가 Resource-2를 점유한 채 Resource-1을 요청함으로써 전형적인 ABBA 순환 대기 교착상태가 발생합니다.
  3. **시스템 도구를 통한 단계적 진단 기법**:
     - **1단계 (생존 여부 확인)**: `ps -ef | grep agent-app-leak`  
       $\to$ 프로세스가 살아있고 PID가 명확히 존재함 (Crash나 정상 종료가 아님).
     - **2단계 (자원 활동성 확인)**: `top -p <PID>` 또는 `vmstat 1`  
       $\to$ CPU 사용률이 0.0%, 메모리(RSS) 증가량 0MB로 완전히 동결됨.
     - **3단계 (스레드 상태 확인)**: `ps -L -o pid,tid,stat,time,wchan:20,comm -p <PID>`  
       $\to$ 스레드들의 상태(STAT)가 `Sl` (인터럽트 가능 수면)이며, 대기 커널 함수(`wchan`)가 `futex_wait_queue` 또는 `futex`에 고착되어 락 대기 중임을 확인.
     - **4단계 (로그 확인)**: `tail -n 20 /var/log/agent-app/agent.log`  
       $\to$ 로그 타임스탬프가 특정 시점 이후 한 줄도 출력되지 않으며 마지막 지점에 `WAITING... BLOCKED` 또는 `POTENTIAL DEADLOCK` 기록이 남음.

---

### 2.4 로그/관제 데이터 기반 장애 기술 및 GitHub Issue 커뮤니케이션

#### Q. 현업 개발팀과 협업할 때 관제 데이터와 로그를 증거로 제시하여 육하원칙에 맞게 장애를 전달하는 이유는 무엇인가?
* **답변**:
  - **재현 불가(Not Reproducible) 방지**: "서버가 죽었습니다"라는 단편적 보고는 개발자가 원인을 파악할 수 없어 조치가 불가능합니다. 정확한 발생 시각(When), 서버 IP 및 PID(Where), 실행 계정 및 환경변수(Who/What), 트리거된 입력 조건(How), 커널 및 애플리케이션 로그(Why)의 육하원칙을 갖추어야 개발자가 로컬 또는 스테이징에서 100% 동일하게 재현할 수 있습니다.
  - **골든 타임 확보 및 책임 분리**: 관제 메트릭(`monitor.sh`의 CPU/MEM 추이, `ps`, `top`)을 함께 첨부하면 인프라 장비 이상인지, OS 리소스 고갈인지, 애플리케이션 코드 결함인지를 신속하게 판별하여 장애 대응 시간을 극적으로 단축합니다.
  - **표준화된 이슈 리포트 포맷**: GitHub Issue 마크다운 템플릿(Description $\to$ Evidence & Logs $\to$ Root Cause $\to$ Workaround & Verification)을 준수함으로써 팀 내 지식 자산(Post-mortem)으로 축적되고 회귀 방지(Regression Test) 테스트 케이스로 활용될 수 있습니다.

---

## 3. 기능 요구사항(Functional Requirements) 상세 답변

### 3.1 사전 준비 사항 및 부트 시퀀스 6단계 검증

`agent-app-leak` 바이너리는 엄격한 부트 시퀀스를 통해 시스템 환경을 검증하며, 단 하나의 조건이라도 불만족 시 즉각 프로세스가 종료됩니다.

#### [요구조건 검증 명세표]

| 항목 | 필수 조건 | 설정값 및 검증 명령어 | 미충족 시 실패 증상 |
|---|---|---|---|
| **실행 계정** | root가 아닌 일반 사용자 | `agent-admin` (uid=1001)<br>`whoami` $\to$ `agent-admin` | `[1/6] Checking User Account [FAIL]`<br>`Running as 'root' is forbidden.` |
| **AGENT_HOME** | 필수 환경변수 | `export AGENT_HOME=/home/agent-admin/agent-app` | `[2/6] Verifying Environment Variables [FAIL]` |
| **AGENT_PORT** | 고정 포트 15034 | `export AGENT_PORT=15034` | 포트 미지정 시 부트 실패 |
| **AGENT_UPLOAD_DIR** | 디렉터리 존재 필수 | `/home/agent-admin/agent-app/upload_files`<br>`mkdir -p $AGENT_UPLOAD_DIR` | `Upload dir does not exist` |
| **AGENT_KEY_PATH** | 디렉터리 경로 필수 | `/home/agent-admin/agent-app/api_keys`<br>`mkdir -p $AGENT_KEY_PATH` | `Key directory not found` |
| **secret.key 파일** | 키 파일 및 특정 문자열 | `$AGENT_KEY_PATH/secret.key`<br>`echo -n "agent_api_key_test" > secret.key` | `[3/6] Checking Required Files [FAIL]`<br>내용 불일치 시 부트 거부 |
| **AGENT_LOG_DIR** | 로그 디렉터리 (쓰기 권한) | `/var/log/agent-app`<br>`chown agent-admin:agent-admin /var/log/agent-app` | `[5/6] Verifying Log Permission [FAIL]` |
| **네트워크** | 0.0.0.0:15034 바인딩 가능 | `ss -tulnp \| grep 15034` 로 사전 점유 확인 | `[4/6] Checking Port Availability [FAIL]` |
| **MEMORY_LIMIT** | 50 ~ 512 범위 (MB) | 예: `export MEMORY_LIMIT=100` | 범위 벗어날 경우 부트 실패 |
| **CPU_MAX_OCCUPY**| 10 ~ 100 범위 (%) | 예: `export CPU_MAX_OCCUPY=100` | 범위 벗어날 경우 부트 실패 |
| **MULTI_THREAD_ENABLE**| true/false (1/0, yes/no) | 예: `export MULTI_THREAD_ENABLE=false` | 부울 파싱 오류 시 부트 실패 |

#### [성공적인 6단계 부트 시퀀스 실행 출력]
```text
>>> Starting Agent Boot Sequence...
[1/6] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1001)
[2/6] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/6] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/6] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/6] Verifying Log Permission            [OK]
   ... Log directory is writable: /var/log/agent-app
[6/6] Verifying Mission Environment       [OK]
   ... MEMORY_LIMIT=100MB, CPU_MAX_OCCUPY=100%, MULTI_THREAD_ENABLE=False
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

---

### 3.2 메모리 누수(OOM Crash) 원인 규명 및 리포팅

#### 1. 요구사항 분석 및 관측 메커니즘
- **트리거 조건**: `MEMORY_LIMIT < 256` (예: `MEMORY_LIMIT=100`)
- **현상 관측**: `agent-leak-app` 내부의 `MemoryWorker`가 3초마다 25MB씩 메모리를 동적 할당하여 반환하지 않고 전역 리스트에 누적(Append)합니다.
- **관제 명령어**: `monitor.sh`를 1초/3초 주기로 실행하여 RSS 메모리 사용량을 추적합니다.
- **핵심 로그**: 물리 메모리가 100MB에 도달하는 시점에 애플리케이션의 `MemoryGuard` 루틴이 발동하여 시스템 불안정을 방지하기 위해 `SIGKILL`을 발행하며 강제 자살(Self-Termination, exit code 137)합니다.

#### 2. Before & After 비교 검증 결과

| 구분 | Before (장애 재현) | After (임시 완화) |
|---|---|---|
| **환경변수 설정** | `MEMORY_LIMIT=100` | `MEMORY_LIMIT=512` |
| **초기 메모리** | 5.1 MB | 5.2 MB |
| **증가 속도** | ~25 MB / 3초 | ~25 MB / 3초 |
| **생존 시간** | **약 12초** | **약 65초 이상 지속 (512MB 도달 시점까지 연장)** |
| **종료 상태코드** | exit 137 (`SIGKILL`) | 생존 시간 5배 이상 증가 확인 |

#### 3. GitHub Issue 리포트 1: OOM Crash

```markdown
# [Bug] 프로세스 실행 12초 후 MemoryGuard 정책에 의한 비정상 강제 종료 (OOM)

## 1. Description (현상 설명)
- **발생 현상**: `agent-app-leak`을 `MEMORY_LIMIT=100` 환경에서 기동 시, 기동 약 12초 후에 예고 없이 프로세스가 강제 종료(Exit code 137)되고 터미널에 `SELF-TERMINATED` 경고가 출력됨.
- **발생 시각 및 환경**: 2026-10-04 07:20:00 KST / Ubuntu 24.04 컨테이너 / 계정 `agent-admin` (PID: 12450)
- **영향도**: 서비스 포트(15034)가 닫히며 클라이언트 접속이 전면 차단됨.

## 2. Evidence & Logs (증거 자료)
- **monitor.sh 수집 관제 로그 (메모리 선형 급증 증거)**:
```text
[2026-10-04 07:20:03] PROCESS:agent-app-leak PID:12450 CPU:1.2% MEM:26MB(1.3%) DISK:48G FIREWALL:active
[2026-10-04 07:20:06] PROCESS:agent-app-leak PID:12450 CPU:1.5% MEM:51MB(2.5%) DISK:48G FIREWALL:active
[2026-10-04 07:20:09] PROCESS:agent-app-leak PID:12450 CPU:1.4% MEM:76MB(3.8%) DISK:48G FIREWALL:active
[2026-10-04 07:20:12] PROCESS:agent-app-leak PID:12450 CPU:1.6% MEM:101MB(5.0%) DISK:48G FIREWALL:active
```
- **프로그램 실행 로그 핵심 발췌 (/var/log/agent-app/agent.log)**:
```text
[2026-10-04 07:20:12] [CRITICAL] [MemoryGuard] Memory limit exceeded (101MB >= 100MB) / (Recommend Over 256MB)
[2026-10-04 07:20:12] [CRITICAL] [MemoryGuard] Self-terminating process 12450 to prevent system instability.
[2026-10-04 07:20:12] >>> [SYSTEM] SELF-TERMINATED (Memory Limit Exceeded) <<<
```
- **프로세스 종료 직후 셸 확인**:
```text
$ echo $?
137
```

## 3. Root Cause Analysis (원인 분석)
- **힙 메모리 누수 결함**: 내부 `MemoryWorker` 스레드가 3초 주기로 25MB의 더미 바이트 배열을 할당하여 전역 큐에 누적하며, 이를 해제하거나 가비지 컬렉션(GC)할 수 있는 포인터를 반환하지 않아 메모리 사용량이 선형적으로 급증함.
- **OS 및 애플리케이션 방어 메커니즘**: 물리 메모리(RSS)가 지정된 `MEMORY_LIMIT` 임계치에 도달하자, OS 레벨의 무차별 OOM-Killer가 시스템 전체 데몬을 죽이는 사태를 방어하기 위해 애플리케이션 내부 `MemoryGuard` 루틴이 자신에게 `SIGKILL(kill -9)` 신호를 전송하여 자살 처리함.

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: `~/.bashrc` 내 환경변수 `MEMORY_LIMIT` 값을 기존 `100`에서 최대 허용치인 `512`로 상향 조정.
  ```bash
  export MEMORY_LIMIT=512
  ```
- **검증 결과 (Before vs After)**:
  - Before (100MB): 기동 후 약 12초 시점에 101MB 도달하며 SIGKILL 종료.
  - After (512MB): 기동 후 약 65초 이상 생존하여 가용 시간을 대폭 확보함.
- **근본 해결 제안 (코드 레벨)**:
  - 전역 버퍼에 저장된 처리 완료 데이터를 주기적으로 pop/clear 처리.
  - 파이썬의 `gc.collect()` 호출 및 `weakref` 참조 활용을 통한 메모리 누수 원천 차단.
```

---

### 3.3 CPU 과점유(CPU Spike) 분석 및 Watchdog 보호 정책 리포팅

#### 1. 요구사항 분석 및 관측 메커니즘
- **트리거 조건**: `MEMORY_LIMIT >= 256`, `CPU_MAX_OCCUPY=100`, `MULTI_THREAD_ENABLE=false`
- **현상 관측**: `CpuWorker`가 기동 후 점진적으로 연산 부하를 증가시키며 단일 코어 CPU 점유율을 100%까지 끌어올립니다.
- **관제 명령어**: `ps -p $PID -o %cpu=`, `top -p $PID`, `monitor.sh`
- **핵심 로그**: CPU 과점유가 지속되자 내부 **Watchdog** 감시자가 시스템 서비스 마비를 방지하기 위해 비상 중단(Emergency Abort) 루틴을 트리거하고 `SIGTERM`(Exit code 143)을 전송하여 종료합니다.

#### 2. Before & After 비교 검증 결과

| 구분 | Before (과점유 장애 재현) | After (임시 완화 / 정상 모드) |
|---|---|---|
| **환경변수 설정** | `CPU_MAX_OCCUPY=100`, `MEMORY_LIMIT=512` | `CPU_MAX_OCCUPY=20`, `MEMORY_LIMIT=512` |
| **CPU 점유율 추이** | 15% $\to$ 45% $\to$ 85% $\to$ **100%** | **15% ~ 20% 이내 제어** |
| **시스템 종료 여부** | **기동 약 34초 후 SIGTERM 강제 종료 (exit 143)** | **정상 모드 유지 (Cooldown 반복, 무중단 생존)** |
| **종료 메시지** | `WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM)` | 주기적 Cooldown 로그 출력되며 정상 운영 |

#### 3. GitHub Issue 리포트 2: CPU Spike

```markdown
# [Bug] 단일 프로세스의 CPU 100% 과점유로 인한 Watchdog 비상 종료 (SIGTERM)

## 1. Description (현상 설명)
- **발생 현상**: `agent-app-leak` 실행 후 약 30초가 경과하면서 CPU 점유율이 100%까지 폭증하고, 직후 `WATCHDOG: INITIATING EMERGENCY ABORT` 메시지와 함께 프로세스가 `SIGTERM`(Exit code 143)으로 중단됨.
- **발생 시각 및 환경**: 2026-10-04 07:25:00 KST / Ubuntu 24.04 컨테이너 / 계정 `agent-admin` (PID: 13110)
- **영향도**: 호스트 CPU 코어가 100% 포화되어 SSH 셸 반응 지연 및 동시 운영 프로세스의 서비스 타임아웃 발생.

## 2. Evidence & Logs (증거 자료)
- **monitor.sh 및 top 관제 로그**:
```text
[2026-10-04 07:25:10] PROCESS:agent-app-leak PID:13110 CPU:22.4% MEM:18MB(0.9%)
[2026-10-04 07:25:20] PROCESS:agent-app-leak PID:13110 CPU:58.7% MEM:18MB(0.9%)
[2026-10-04 07:25:30] PROCESS:agent-app-leak PID:13110 CPU:92.1% MEM:18MB(0.9%) [WARNING] Process CPU > 80% (92.1%)
[2026-10-04 07:25:34] PROCESS:agent-app-leak PID:13110 CPU:99.8% MEM:18MB(0.9%) [WARNING] Process CPU > 80% (99.8%)
```
- **애플리케이션 실행 로그 발췌**:
```text
[2026-10-04 07:25:32] [WARN] [CpuWorker] CPU workload reached peak threshold (99.8% >= 100.0%)
[2026-10-04 07:25:34] [CRITICAL] [Watchdog] CPU hogging detected continuously for over threshold duration!
[2026-10-04 07:25:34] >>> [SYSTEM] WATCHDOG: INITIATING EMERGENCY ABORT (SIGTERM) <<<
```
- **프로세스 종료 코드 확인**:
```text
$ echo $?
143
```

## 3. Root Cause Analysis (원인 분석)
- **연산 루프의 자원 독점**: `CpuWorker` 내부에서 비동기 I/O 대기나 `sleep(yield)` 없이 연속적인 행렬 연산 또는 무한 루프를 실행하여 타임 슬라이스를 소진하고 코어를 독점함.
- **Watchdog 보호 정책 트리거**: 시스템 전체가 무응답 상태에 빠져 다른 필수 서비스(웹 서버, DB 등)가 Starvation(기아 상태)에 처하는 것을 막기 위해, 백그라운드 Watchdog 모니터가 정책에 따라 해당 프로세스에 `SIGTERM`을 발행함.

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: `CPU_MAX_OCCUPY` 환경변수를 기존 100에서 20으로 하향 조정.
  ```bash
  export CPU_MAX_OCCUPY=20
  export MEMORY_LIMIT=512
  export MULTI_THREAD_ENABLE=false
  ```
- **검증 결과 (Before vs After)**:
  - Before (`CPU_MAX_OCCUPY=100`): 기동 약 34초 만에 CPU 100% 도달 $\to$ SIGTERM 비상 종료.
  - After (`CPU_MAX_OCCUPY=20`): CPU 점유율이 20%를 초과하지 않고 정기적으로 Cooldown 모드로 진입하며 프로세스가 종료 없이 계속 정상 서빙됨.
- **근본 해결 제안 (코드 레벨)**:
  - 대량 연산 루프 사이에 `time.sleep(0.001)` 또는 OS 스케줄러 양보(`sched_yield()`) 호출 삽입.
  - CPU-bound 작업을 백그라운드 분산 큐(Celery, Ray 등)로 이관하여 메인 워커 스레드 부하 분산.
```

---

### 3.4 교착상태(Deadlock) 진단 및 스레드 자원 대기 상태 분석

#### 1. 요구사항 분석 및 관측 메커니즘
- **트리거 조건**: `MEMORY_LIMIT >= 256`, `CPU_MAX_OCCUPY <= 20`, `MULTI_THREAD_ENABLE=true`
- **현상 관측**: 프로세스는 종료되지 않고 실행 중(PID 유지)이지만, 터미널 로그 출력이 완전히 멈추고 CPU 사용률 0.0%, 메모리 변동 0MB로 시스템이 무응답 상태에 빠집니다.
- **진단 도구**: `ps -ef`, `top -H`, `ps -L -o pid,tid,stat,wchan,comm`, `strace`
- **논리적 증명**: 멀티스레드 환경에서 Thread-A와 Thread-B가 각각 락을 쥐고 상대방의 락을 대기하는 순환 대기(Circular Wait) 발생.

#### 2. Before & After 비교 검증 결과

| 구분 | Before (멀티스레드 데드락 재현) | After (싱글스레드 회피) |
|---|---|---|
| **환경변수 설정** | `MULTI_THREAD_ENABLE=true` | `MULTI_THREAD_ENABLE=false` |
| **PID 상태** | 프로세스 유지 (종료되지 않음) | 프로세스 유지 |
| **CPU / MEM 변동** | **CPU 0.0%, MEM 변화 정체** | 정상적인 활동 수치 기록 |
| **로그 출력** | **"WAITING... BLOCKED" 이후 정지** | 주기적인 정상 관제 로그 연속 출력 |
| **스레드 상태** | 복수 스레드가 `futex_wait` 상태에 고착 | 단일 스레드가 순차 처리 정상 완료 |

#### 3. GitHub Issue 리포트 3: Deadlock

```markdown
# [Bug] 멀티스레드 활성화 시 상호 락 경합으로 인한 영구 교착상태(Deadlock) 발생

## 1. Description (현상 설명)
- **발생 현상**: `MULTI_THREAD_ENABLE=true` 설정 후 기동 시, 초기 부트 및 작업 시작 후 수 초 내에 로그 출력이 영구 정지됨. 프로세스는 종료되지 않고 살아있으나(PID 유지) 네트워크 요청 응답 및 파일 처리가 완전히 멈춤.
- **발생 시각 및 환경**: 2026-10-04 07:30:00 KST / Ubuntu 24.04 컨테이너 / 계정 `agent-admin` (PID: 14220)
- **영향도**: 프로세스가 좀비/락업 상태에 빠져 사용자의 모든 트랜잭션이 무한 행(Hang)에 걸림.

## 2. Evidence & Logs (증거 자료)
- **프로세스 생존 증거 (ps -ef)**:
```text
agent-ad+ 14220 13800  0 07:30 pts/1    00:00:01 /home/agent-admin/agent-app/agent-app-leak
```
- **스레드별 무응답 및 futex 대기 증거 (ps -L)**:
```text
  PID   TID STAT  %CPU %MEM WCHAN                COMMAND
14220 14220 Sl     0.0  0.9 do_sys_poll          agent-app-leak
14220 14221 Sl     0.0  0.9 futex_wait_queue_me  Worker-Thread-A
14220 14222 Sl     0.0  0.9 futex_wait_queue_me  Worker-Thread-B
```
- **프로그램 마지막 실행 로그 발췌**:
```text
[2026-10-04 07:30:05] [INFO] [Worker-Thread-A] Acquired Resource-Lock-1. Attempting to acquire Resource-Lock-2...
[2026-10-04 07:30:05] [INFO] [Worker-Thread-B] Acquired Resource-Lock-2. Attempting to acquire Resource-Lock-1...
[2026-10-04 07:30:05] [WARN] [Worker-Thread-A] WAITING... BLOCKED on Resource-Lock-2 (Held by TID 14222)
[2026-10-04 07:30:05] [WARN] [Worker-Thread-B] WAITING... BLOCKED on Resource-Lock-1 (Held by TID 14221)
[2026-10-04 07:30:05] [CRITICAL] POTENTIAL DEADLOCK DETECTED! Both threads entering unrecoverable circular wait.
--- (이후 로그 출력 완전히 단절됨) ---
```

## 3. Root Cause Analysis (원인 분석)
- **교착상태 4대 조건 성립 확인**:
  1. **상호 배제 (Mutual Exclusion)**: Resource-1과 Resource-2는 동시 접근이 불가능한 배타적 Mutex로 보호됨.
  2. **점유 대기 (Hold and Wait)**: Worker-A는 Lock-1을 보유한 채 Lock-2를 요구하고, Worker-B는 Lock-2를 보유한 채 Lock-1을 요구함.
  3. **비선점 (No Preemption)**: 상대 스레드가 보유한 락을 강제로 회수할 수 없음.
  4. **순환 대기 (Circular Wait)**: Worker-A $\to$ Worker-B $\to$ Worker-A 형태의 환형 대기 체인 완성.
- **결론**: 리소스 획득 순서가 일관되지 않아 발생한 전형적인 교착상태이며, OS 커널 수준에서 `futex`(Fast Userspace Mutex) 슬립에 들어가 CPU를 소모하지 않은 채 영구 대기함.

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: 병렬 스레드 경합을 원천 차단하기 위해 멀티스레드 플래그 비활성화.
  ```bash
  export MULTI_THREAD_ENABLE=false
  ```
- **검증 결과 (Before vs After)**:
  - Before (`MULTI_THREAD_ENABLE=true`): 기동 5초 후 Worker-A와 Worker-B 간 교착상태 발생하여 프로세스 무응답 영구 고착.
  - After (`MULTI_THREAD_ENABLE=false`): 단일 스레드로 자원을 순차 점유/반납하여 데드락이 100% 회피되고 정상 실행 완료됨.
- **근본 해결 제안 (코드 레벨)**:
  - **락 획득 순서 정규화 (Lock Ordering)**: 모든 스레드가 반드시 Lock-1을 먼저 획득한 후 Lock-2를 획득하도록 강제 규칙 적용.
  - **타임아웃 적용 (Lock with Timeout)**: `acquire(timeout=5)`를 적용하여 일정 시간 내 획득 실패 시 보유 락을 모두 반납하고 재시도하는 Backoff 알고리즘 구현.
```

---

## 4. 보너스 과제: 로그 패턴 분석을 통한 스케줄링 알고리즘 역추론

### 4.1 로그 관찰 및 증거 자료 수집

정상 상태에서 3개의 워커 스레드(`Thread-A`, `Thread-B`, `Thread-C`)가 수행하는 작업 로그를 타임스탬프와 함께 수집하였습니다.

```text
[2026-10-04 07:35:00.100] [Thread-A] Task Started. Calculating... (10%)
[2026-10-04 07:35:00.150] [Thread-A] Calculating... (20%)
[2026-10-04 07:35:00.200] [Thread-B] Task Started. Calculating... (10%)  <-- Thread-A 완료 전 중단, Thread-B 선점
[2026-10-04 07:35:00.250] [Thread-B] Calculating... (20%)
[2026-10-04 07:35:00.300] [Thread-C] Task Started. Calculating... (10%)  <-- Thread-B 완료 전 중단, Thread-C 선점
[2026-10-04 07:35:00.350] [Thread-A] Resumed. Calculating... (30%)       <-- Thread-C 중단, Thread-A 재개
[2026-10-04 07:35:00.400] [Thread-B] Resumed. Calculating... (30%)       <-- Thread-A 중단, Thread-B 재개
[2026-10-04 07:35:00.450] [Thread-C] Resumed. Calculating... (20%)       <-- Thread-B 중단, Thread-C 재개
```

---

### 4.2 스케줄링 기법 역추론 분석

1. **FCFS(First-Come, First-Served) 배제 근거**:
   - FCFS 방식이라면 가장 먼저 시작한 `Thread-A`가 100% 작업을 마칠 때까지 CPU를 독점해야 합니다. 하지만 로그에서 `Thread-A`가 20%만 수행된 시점(100ms 경과)에 `Thread-B`로 전환되었으므로 **비선점형 FCFS가 아님**이 명백합니다.
2. **Priority(우선순위) 스케줄링 배제 근거**:
   - 특정 스레드가 높은 우선순위를 가졌다면 다른 스레드를 배제하고 독점 실행되거나 불균등한 비율로 실행되어야 합니다. 그러나 `A -> B -> C -> A -> B -> C` 순으로 모든 스레드가 공평하게 번갈아 실행되고 있으므로 **정적 우선순위 기반 스케줄링이 아님**을 알 수 있습니다.
3. **최종 결론: 라운드 로빈 (Round-Robin, RR)**:
   - 각 스레드는 정해진 타임 슬라이스(Time Quantum, 약 100ms) 동안만 CPU를 점유한 후, 타임아웃 인터럽트에 의해 자원을 반납하고 큐의 맨 뒤로 이동합니다.
   - 따라서 작업 순환 주기(`A -> B -> C -> A`)와 시간 균등 분배 특성으로 볼 때 **선점형 라운드 로빈(Round-Robin) 알고리즘**으로 최종 결론을 내립니다.

---

### 4.3 기술적 장단점 및 적합 아키텍처 비교

| 항목 | 라운드 로빈 (Round-Robin) | FCFS (선입선출) | 우선순위 (Priority) |
|---|---|---|---|
| **응답 시간 (Response Time)** | **매우 빠름** (모든 작업이 즉시 시작됨) | 긴 작업 뒤에 오면 매우 느림 (Convoy Effect) | 높은 우선순위 작업은 빠름 |
| **처리량 (Throughput)** | 중간 (문맥 교환 오버헤드 존재) | **높음** (문맥 교환 없음) | 중간 |
| **공평성 (Fairness)** | **완벽히 공평함 (기아 현상 없음)** | 순서대로 처리되나 짧은 작업에 불리 | 낮음 (낮은 순위 작업의 Starvation 발생) |
| **적합한 시스템 아키텍처** | **대화형 시스템, 실시간 웹 서버, 마이크로서비스 API Gateway** | **배치(Batch) 대용량 연산 서버, 비디오 인코딩 시스템** | **실시간 제어 시스템(RTOS), 긴급 패킷 라우터** |

---

## 5. 시스템 평가 심화 Q&A (Eval 핵심 문항 연계)

미션 평가(`b4_2_Eval.pdf`)의 기술 질문들에 대한 종합 답변입니다.

### Q1. `monitor.sh`에서 메모리 증가 패턴을 추적하기 위해 사용한 명령어와 데이터 추출 방법은 무엇인가?
* **답변**:
  - **명령어**: `ps -p "$PID" -o rss=` 및 `awk`
  - **데이터 추출 원리**:
    - `ps -p "$PID" -o rss=`: 대상 프로세스의 실제 물리 메모리 상주 크기(Resident Set Size)를 KB 단위의 순수 숫자로 추출합니다.
    - `awk '{printf "%.0f", $1/1024}'`: 추출된 KB 값을 1024로 나누어 운영자가 직관적으로 파악할 수 있는 **MB 단위 정수**로 변환합니다.
    - `ps -p "$PID" -o %mem=`: 시스템 전체 물리 메모리 대비 해당 프로세스의 백분율 점유율을 함께 수집하여 단일 프로세스 과부하 여부를 판별합니다.

### Q2. 프로세스의 CPU 사용률 확인을 위해 선택한 도구와 옵션의 의미는?
* **답변**:
  - `ps -p "$PID" -o %cpu=`: 프로세스 생명주기 전체에 걸친 누적 CPU 사용률 평균치 또는 최근 인터벌의 사용률을 스크립트 친화적인 파싱 텍스트로 추출합니다.
  - `top -p "$PID" -b -n 1`: 배치 모드(`-b`)로 1회(`-n 1`) 순간 샘플링하여 실시간 CPU 급증(Spike) 순간 점유율을 즉시 포착합니다.
  - `ps -p "$PID" -L -o pid,tid,pcpu,stat`: 프로세스 내부의 개별 스레드(TID)별로 CPU 사용률을 분해하여, 특정 연산 스레드(`CpuWorker`)가 코어를 100% 독점하고 있는지 파악합니다.

### Q3. 프로세스가 "살아있지만 멈춰있는 상태(Deadlock)"를 진단하기 위한 도구 사용 순서와 판단 흐름은?
* **답변**:
  1. **1단계 (`pgrep` / `ps -ef`)**: 프로세스가 예기치 않게 죽었는지(Crash), 아니면 PID를 유지하며 살아있는지 확인합니다. $\to$ **PID가 정상 조회됨.**
  2. **2단계 (`top -p <PID>` / `vmstat`)**: 살아있는 프로세스가 CPU나 메모리 I/O 작업을 수행 중인지 확인합니다. $\to$ **CPU 0.0%, 메모리 변동 전혀 없음.**
  3. **3단계 (`ps -L -o pid,tid,stat,wchan:20`)**: 프로세스 내부 스레드들의 상태와 커널 대기 함수를 확인합니다. $\to$ **스레드들이 `futex_wait_queue`에서 멈춰있음을 포착.**
  4. **4단계 (`tail -f /var/log/...`)**: 애플리케이션 로그에 신규 이벤트가 전혀 찍히지 않고 마지막 로그가 `WAITING... BLOCKED`임을 확인하여 데드락으로 최종 단정합니다.

### Q4. 메모리 누수 발생 시 애플리케이션의 메모리 보호 정책(MemoryGuard)이 해당 프로세스를 강제 종료하는 이유는?
* **답변**:
  - 메모리 누수를 방치하면 호스트 OS의 가용 메모리가 0에 도달하여 시스템 커널의 `OOM-Killer`가 활성화됩니다.
  - 커널 `OOM-Killer`는 휴리스틱 알고리즘에 의해 데이터베이스(MySQL), 웹 서버(Nginx), 원격 접속 데몬(SSHD) 등 핵심 시스템 프로세스를 무차별 강제 종료할 위험이 있습니다.
  - 따라서 문제가 발생한 프로세스 스스로가 임계치(`MEMORY_LIMIT`) 도달 시 자살(`SIGKILL`)함으로써 호스트 시스템의 안정성과 다른 테넌트 서비스의 생존을 보장하기 위함입니다.

### Q5. CPU 과점유 시 단일 프로세스를 종료(Watchdog)하는 것이 시스템 보호에 왜 필요한가?
* **답변**:
  - CPU 코어가 100% 독점되면 운영체제의 스케줄러 오버헤드가 급증하고, 다른 프로세스가 실행 큐(Runqueue)에서 대기하며 기아(Starvation) 상태에 빠집니다.
  - 특히 네트워크 드라이버 인터럽트(SoftIRQ), 헬스체크 핑(Ping), 로드밸런서 Keep-Alive 패킷 처리가 불가해져 서버 인프라 전체가 '다운'된 것으로 인식되어 대규모 장애로 전파됩니다.
  - 따라서 과점유 워커를 조기 격리/종료(`SIGTERM`)하여 OS의 제어권과 반응성을 회복시키는 것이 필수적입니다.

### Q6. 운영 서버에서 메모리 누수를 장애 발생 전에 조기 탐지하기 위해 `monitor.sh`를 어떻게 개선하겠는가?
* **답변**:
  1. **메모리 증가 기울기(Rate of Change) 감시 로직 추가**: 단순히 절대값 임계치(예: 30%)만 보는 것이 아니라, 최근 5회 관측 데이터 간의 $d(MEM)/dt$ 기울기를 계산하여 3연속 선형 증가 시 "Memory Leak Suspected" 조기 경보를 발생시킵니다.
  2. **임계치 2단계 세분화 (Warning 70%, Critical 85%)**: Critical 도달 시 엔지니어 개입 전에 자동으로 프로세스 힙 덤프(`jmap`, `gcore`, `tracemalloc`)를 남기도록 개선합니다.
  3. **알림 채널 연동**: 슬랙(Slack) 웹훅, PagerDuty, 이메일 API를 스크립트에 curl로 연동하여 당직자에게 즉각 발송합니다.

### Q7. 3가지 장애(OOM, CPU Spike, Deadlock) 중 실제 서비스 환경에서 가장 치명적인 것은 무엇이며 근본 예방책은?
* **답변**:
  - **가장 치명적인 장애: Deadlock (교착상태)**
  - **이유**:
    - OOM이나 CPU Spike는 프로세스가 크래시되거나 종료 신호를 받아 죽기 때문에 쿠버네티스(k8s)나 systemd 같은 프로세스 오케스트레이터가 재기동(Restart)시켜 일시 복구할 수 있으며 관제 시스템(Prometheus, Datadog)에 쉽게 감지됩니다.
    - 반면 Deadlock은 **PID가 살아있고 CPU 사용률도 0%**이므로 단순 프로세스 생존 헬스체크를 통과하여 관제망을 완벽히 속입니다. 그 사이 들어오는 모든 사용자 요청이 큐에 쌓여 타임아웃되고 커넥션 풀이 고갈되어 시스템 전체를 소리 없이 마비시킵니다.
  - **근본 예방책**:
    - **락 순서화(Lock Ordering Hierarchy)**: 자원 간 계층 구조를 정의하여 모든 스레드가 동일한 순서로만 락을 요청하도록 강제합니다.
    - **TryLock with Timeout**: 영구 대기하는 `mutex.acquire()`를 금지하고 최대 대기 시간(`try_acquire(timeout=2s)`)을 설정합니다.
    - **Lock-Free 자료구조 도입**: 원자적 연산(Atomic CAS) 및 동시성 큐(Concurrent Queue)를 사용하여 상호 배제 필요성을 최소화합니다.

### Q8. 동일 서버에서 OOM과 Deadlock이 동시 발생했다면 트러블슈팅 우선순위와 근거는?
* **답변**:
  - **우선순위**: **1순위: OOM 처리 $\to$ 2순위: Deadlock 처리**
  - **근거**:
    - **OOM**은 시스템 전체의 물리 메모리를 고갈시켜 OS 커널 패닉, 스왑 쓰레싱, 타 프로세스 연쇄 강제 종료를 일으키는 **급성 시스템 파괴 장애**입니다. 호스트 머신 전체가 다운되는 것을 막기 위해 메모리 누수 프로세스를 즉시 강제 종료(`kill -9`)하여 가용 메모리를 확보하는 것이 최우선입니다.
    - **Deadlock**은 해당 프로세스 내부 스레드 간의 논리적 고착 상태로, 시스템 전체 메모리나 CPU를 물리적으로 파괴하지는 않는 국소적 무응답 장애입니다. 따라서 시스템 인프라 생존(OOM 진화)을 먼저 확보한 뒤, 스레드 덤프(`jstack`, `pstack`)를 채증하여 데드락 원인 코드를 정밀 분석하는 순서로 접근해야 합니다.

### Q9. 소스 코드를 직접 수정할 수 있다면 각 장애 유형별 코드 레벨의 개선책은?
* **답변**:
  1. **Memory Leak 개선**:
     - 대용량 임시 데이터를 담는 컨테이너에 대해 작업 완료 후 명시적 `clear()` 또는 `del` 호출.
     - 순환 참조(Circular Reference) 방지를 위한 `weakref` 모듈 적용 및 캐시 크기 제한(LRU Cache, Max Size 설정).
  2. **CPU Spike 개선**:
     - Intensive 연산 루프 내에 `asyncio.sleep(0)` 또는 타임 슬라이스 양보(`sched_yield`) 삽입.
     - 불필요한 폴링(Polling) 루프를 이벤트 기반(Event-Driven, epoll, Condition Variable) 아키텍처로 전환.
  3. **Deadlock 개선**:
     - 다중 락 획득 시 전역 락 정렬기(Global Lock Sorter)를 구현하여 리소스 ID 순서대로만 락을 획득하도록 구현.
     - 락 획득 실패 시 기획득한 모든 락을 반환하고 지수 백오프(Exponential Backoff) 후 재시도하도록 리팩토링.
