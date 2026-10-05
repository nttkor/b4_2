# `agent-app-leak` 시스템 장애 분석 및 실습 매뉴얼 (`demo_manual.md`)

> **대상 시스템**: macOS (Intel Core i5, x86_64) + OrbStack Docker 환경  
> **대상 바이너리**: `agent-app-leak` (Linux ELF 64-bit)  
> **컨테이너 환경**: Ubuntu 24.04 LTS (`agent-leak-lab`)  
> **문서 목적**: 호스트(macOS)에서 도커 컨테이너를 구동하고, 6단계 부트 시퀀스를 통과하여 3대 장애(Deadlock, OOM, CPU Spike)를 재현 및 관제하는 전체 과정을 한눈에 따라 할 수 있도록 정리한 실전 가이드입니다.

---

## 📌 목차
1. [사전 이해: macOS와 Linux 바이너리](#1-사전-이해-macos와-linux-바이너리)
2. [Step 1: Docker 컨테이너 생성 및 기동 (macOS 호스트)](#step-1-docker-컨테이너-생성-및-기동-macos-호스트)
3. [Step 2: 컨테이너 초기 환경 구성 (Root 계정 작업)](#step-2-컨테이너-초기-환경-구성-root-계정-작업)
4. [Step 3: 계정 전환 및 공통 환경변수 설정 (`agent-admin`)](#step-3-계정-전환-및-공통-환경변수-설정-agent-admin)
5. [Step 4: 장애 시나리오별 실행 및 재현](#step-4-장애-시나리오별-실행-및-재현)
6. [Step 5: 실시간 관제 및 상태 확인 (별도 터미널)](#step-5-실시간-관제-및-상태-확인-별도-터미널)
7. [자주 겪는 트러블슈팅 FAQ](#자주-겪는-트러블슈팅-faq)

---

## 1. 사전 이해: macOS와 Linux 바이너리

* **바이너리 파일 성격**: `agent-app-leak` 및 `agent-leak-app-x86`은 **Linux 64-bit ELF** 실행 파일입니다.
* **맥 터미널 실행 불가**: 맥 터미널(`zsh`)에서 직접 실행하면 `zsh: exec format error`가 발생합니다.
* **해결책**: macOS에서 동작하는 Docker(OrbStack)를 통해 **Ubuntu 24.04 Linux 컨테이너 내부**에서 실행해야 합니다.

---

## Step 1: Docker 컨테이너 생성 및 기동 (macOS 호스트)

맥 터미널(`mpeg46551@c3r3s7 b4_2 %`)에서 아래 절차를 진행합니다.

### 1-1. OrbStack 앱 실행
Finder 또는 Spotlight에서 **OrbStack.app**을 실행하여 백그라운드 Docker 엔진을 활성화합니다.

### 1-2. 최초 컨테이너 생성 및 프로젝트 마운트
현재 작업 디렉터리(`b4_2`)를 컨테이너 내 `/home/agent-admin/agent-app`으로 바인드 마운트하여 기동합니다.

```bash
docker run -it --name agent-leak-lab -v /Users/mpeg46551/b4_2:/home/agent-admin/agent-app ubuntu:24.04 bash
```
> **Tip: 이미 컨테이너가 만들어져 있는 경우 (재접속 시)**:
> ```bash
> docker start agent-leak-lab
> docker exec -it agent-leak-lab bash
> ```

정상 진입되면 프롬프트가 `root@<컨테이너ID>:/#` 로 바뀝니다.

---

## Step 2: 컨테이너 초기 환경 구성 (Root 계정 작업)

`root@<컨테이너ID>:/#` 상태에서 최초 1회 아래 명령어들을 실행합니다.

### 2-1. 필수 시스템 유틸리티 설치
```bash
apt-get update && apt-get install -y procps iproute2
```

### 2-2. 전용 계정(`agent-admin`, UID 1001) 생성 및 Bash 쉘 지정
`agent-app-leak`은 root 권한 실행을 엄격히 금지합니다.
```bash
useradd -m -s /bin/bash -u 1001 agent-admin
```

### 2-3. 기본 쉘 프로필 템플릿 복사 (프롬프트 경로 정상 출력용)
홈 디렉터리에 `.bashrc`를 복사하여 `사용자@호스트:경로$` 프롬프트가 정상 표시되도록 합니다.
```bash
cp /etc/skel/.bashrc /etc/skel/.profile /home/agent-admin/
```

### 2-4. 부트 시퀀스 필수 디렉터리 및 인증키 파일 생성
바이너리가 기동 시 요구하는 파일과 디렉터리를 생성하고 권한을 부여합니다.
```bash
# 디렉터리 생성
mkdir -p /home/agent-admin/agent-app/upload_files
mkdir -p /home/agent-admin/agent-app/api_keys
mkdir -p /var/log/agent-app

# 인증키 발급 (내용: agent_api_key_test, 권한: 600)
echo -n "agent_api_key_test" > /home/agent-admin/agent-app/api_keys/secret.key
chmod 600 /home/agent-admin/agent-app/api_keys/secret.key

# 소유권 agent-admin으로 이전
chown -R agent-admin:agent-admin /home/agent-admin
chown -R agent-admin:agent-admin /var/log/agent-app
```

---

## Step 3: 계정 전환 및 공통 환경변수 설정 (`agent-admin`)

### 3-1. `agent-admin` 계정으로 전환
```bash
su - agent-admin
```
*(프롬프트가 `agent-admin@<컨테이너ID>:~$` 로 변경됩니다)*

### 3-2. 공통 환경변수 설정 및 디렉터리 이동
```bash
cd /home/agent-admin/agent-app

export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files
export AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
```

---

## Step 4: 장애 시나리오별 실행 및 재현

환경변수 조합에 따라 4가지 모드로 동작합니다.

### 4-1. 데드락 (Deadlock) 재현 시나리오
서로 다른 스레드가 자원 A, B의 락(Mutex)을 쥐고 상대방 락을 요구하는 상호 대기 상태를 유발합니다.
```bash
export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=20 MULTI_THREAD_ENABLE=true
./agent-app-leak
```
* **관찰 현상**:
  - `LOCK ACQUIRED: [Shared_Memory_A]` & `LOCK ACQUIRED: [Socket_Pool_B]` 출력
  - `WAITING for [Socket_Pool_B]... (Status: BLOCKED)` 출력 후 **출력 영구 정지**
  - CPU 0.0%, 메모리 변동 0MB로 무응답 Hang 상태 진입 (죽지 않고 PID 유지)
* **종료 방법**: 터미널에서 `Ctrl + C`

---

### 4-2. OOM (메모리 누수) 재현 시나리오
`MemoryWorker`가 3초마다 25MB씩 힙 메모리를 누적 할당하여 한계 도달 시 자가 강제 종료됩니다.
```bash
export MEMORY_LIMIT=100 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false
./agent-app-leak
echo "종료 코드: $?"
```
* **관찰 현상**: 기동 약 12초 후 100MB를 초과하자 `MemoryGuard`에 의해 `SIGKILL` 자살 (`exit 137`).

---

### 4-3. CPU 과점유 (CPU Spike) 재현 시나리오
`CpuWorker`가 점진적으로 CPU 점유율을 100%까지 끌어올립니다.
```bash
export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false
./agent-app-leak
echo "종료 코드: $?"
```
* **관찰 현상**: 기동 약 34초 후 CPU 100% 도달 시 시스템 마비를 막기 위해 `Watchdog`이 `SIGTERM` 비상 중단 (`exit 143`).

---

### 4-4. 정상 모드 (Healthy Monitoring) 시나리오
임시 완화(Workaround) 설정으로, 락 경합과 과부하 없이 영구 서비스 유지되는 상태입니다.
```bash
export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=20 MULTI_THREAD_ENABLE=false
./agent-app-leak
```
* **관찰 현상**: Cooldown 로그를 주기적으로 출력하며 프로세스가 종료 없이 계속 서빙 유지.

---

## Step 5: 실시간 관제 및 상태 확인 (별도 터미널)

프로세스가 실행 중이거나 데드락에 빠져 있을 때, **맥에서 새로운 터미널 창**을 열어 컨테이너에 접속 후 상태를 확인합니다.

```bash
# 맥 터미널에서 실행 중인 컨테이너에 접속
docker exec -it agent-leak-lab bash
su - agent-admin
cd /home/agent-admin/agent-app
```

### 관제 명령어 모음

| 점검 목적 | 명령어 | 설명 |
|---|---|---|
| **프로세스 생존 확인** | `ps aux \| grep agent-app-leak` | PID 존재 여부, CPU %, MEM % 확인 |
| **스레드 레벨 데드락 확인** | `ps -eLf \| grep agent-app-leak` | 3개 스레드(LWP)가 `Sl` 상태로 대기 중인지 확인 |
| **전용 관제 스크립트 실행** | `./bin/monitor.sh` | CPU, RSS MB, 디스크, 포트, 경보 로그 1회 수집 |
| **실시간 로그 스트리밍** | `tail -f /var/log/agent-app/monitor.log` | 관제 스크립트가 수집한 기록 확인 |
| **포트 리스닝 확인** | `ss -tulnp \| grep 15034` | 서비스 포트 바인딩 상태 확인 |

---

## 자주 겪는 트러블슈팅 FAQ

### Q1. `zsh: exec format error: ./agent-app-leak` 에러가 발생합니다.
* **원인**: macOS 터미널에서 직접 Linux ELF 바이너리를 실행하려 했기 때문입니다.
* **해결**: Step 1에 따라 `docker run` 또는 `docker exec`로 **우분투 컨테이너 내부**로 들어가서 실행해야 합니다.

### Q2. `bash: docker: command not found` 에러가 납니다.
* **원인**: 이미 Docker 컨테이너(`root@<컨테이너ID>:/#`) 내부로 진입한 상태에서 또 `docker` 명령어를 쳤기 때문입니다.
* **해결**: 이미 리눅스 환경 안에 계시므로, Step 2의 계정 설정(`su - agent-admin`)으로 바로 진행하시면 됩니다.

### Q3. 프롬프트가 `agent-admin@...` 대신 단순한 `$` 로만 표시됩니다.
* **원인**: `agent-admin` 홈 폴더에 `.bashrc`가 없거나 쉘이 `/bin/sh`로 열린 경우입니다.
* **해결**: 
  1. `root` 계정에서 `cp /etc/skel/.bashrc /home/agent-admin/` 실행
  2. 또는 `agent-admin` 상태에서 `bash` 명령어를 입력하여 Bash 쉘을 다시 로드합니다.

### Q4. 부트 시퀀스 `[1/6] Checking User Account [FAIL]` 발생
* **원인**: `root` 계정으로 실행했기 때문입니다.
* **해결**: 반드시 `su - agent-admin`으로 전환한 뒤 실행하세요.

### Q5. 부트 시퀀스 `[3/6] Checking Required Files [FAIL]` 발생
* **원인**: `secret.key` 파일이 없거나 내용이 일치하지 않습니다.
* **해결**: 
  ```bash
  echo -n "agent_api_key_test" > /home/agent-admin/agent-app/api_keys/secret.key
  chmod 600 /home/agent-admin/agent-app/api_keys/secret.key
  ```

### Q6. `tail: cannot open '/var/log/agent-app/agent.log'` 에러가 납니다.
* **원인**: 실제 애플리케이션 로그 파일명은 `agent.log`가 아니라 언더스코어(`_`)가 포함된 **`agent_app.log`**입니다.
* **해결**: `tail -n 15 /var/log/agent-app/agent_app.log` 로 조회합니다.

### Q7. `ps -L`로 조회했을 때 스레드가 1개만 보이고 WCHAN이 `do_wait`로 나옵니다.
* **원인**: `agent-app-leak`은 런처(부모 프로세스)와 실제 파이썬 워커(자식 프로세스) 2개로 실행됩니다. 첫 번째 PID는 자식을 기다리는 부모(`do_wait`)입니다.
* **해결**: 실제 3개 스레드를 보유한 자식 프로세스 PID(예: PID 274)를 조회해야 합니다 (`ps -L -p <자식PID>`).

---

## 8. 실습 채증 데이터 및 검증 로그 (실제 수행 기록)

2026-10-05 실제 Ubuntu 24.04 컨테이너 환경에서 수행한 전체 검증 로그입니다.

### 8-1. 데드락 재현 및 부트 시퀀스 통과
```text
$ ./agent-app-leak
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
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=20%, MULTI_THREAD_ENABLE=True
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
2026-10-05 00:41:57,449 [INFO] [SafetyGuard] Process priority lowered (nice=10).
2026-10-05 00:41:57,449 [INFO] Agent listening at port 15034

==================================================
 [ Agent Initiate ] Resource Check 
==================================================
 [ MEMORY ] Limit: 512MB                [ OK ]
 [ CPU    ] Limit: 20%                  [ OK ]
 [ THREAD ] Concurrency: True           [ WARNING ]
--------------------------------------------------
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
==================================================

2026-10-05 00:41:59,451 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
2026-10-05 00:41:59,451 [WARNING] [System] CAUTION: Strict resource locking is enabled.
2026-10-05 00:42:04,453 [INFO] [Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
2026-10-05 00:42:04,454 [INFO] [AgentWorker][Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
2026-10-05 00:42:04,454 [INFO] [AgentWorker] Waiting for worker threads to complete transactions...
2026-10-05 00:42:04,454 [INFO] [AgentWorker][Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-10-05 00:42:04,454 [INFO] [AgentWorker][Worker-Thread-1] Processing critical data in Memory A...
2026-10-05 00:42:04,454 [INFO] [AgentWorker][Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
2026-10-05 00:42:04,455 [INFO] [AgentWorker][Worker-Thread-2] Establishing network connections in Pool B...
2026-10-05 00:42:06,456 [INFO] [AgentWorker][Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
2026-10-05 00:42:06,457 [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
2026-10-05 00:42:06,457 [INFO] [AgentWorker][Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
2026-10-05 00:42:06,457 [INFO] [AgentWorker][Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```

### 8-2. 실시간 프로세스 및 스레드 관제 (2번 터미널)
```text
agent-admin@03fbe9ff8e40:~/agent-app$ ps aux | grep agent-app-leak
agent-a+     273  0.0  0.0   2908  2024 pts/0    S+   00:41   0:00 ./agent-app-leak
agent-a+     274  0.0  0.0 174588 11784 pts/0    SNl+ 00:41   0:00 ./agent-app-leak

agent-admin@03fbe9ff8e40:~/agent-app$ ps -eLf | grep agent-app-leak
agent-a+     273     270     273  0    1 00:41 pts/0    00:00:00 ./agent-app-leak
agent-a+     274     273     274  0    3 00:41 pts/0    00:00:00 ./agent-app-leak
agent-a+     274     273     275  0    3 00:42 pts/0    00:00:00 ./agent-app-leak
agent-a+     274     273     276  0    3 00:42 pts/0    00:00:00 ./agent-app-leak

agent-admin@03fbe9ff8e40:~/agent-app$ ps -L -o pid,tid,stat,%cpu,%mem,comm -p 274
    PID     TID STAT %CPU %MEM COMMAND
    274     274 SNl+  0.0  0.0 agent-app-leak
    274     275 SNl+  0.0  0.0 agent-app-leak
    274     276 SNl+  0.0  0.0 agent-app-leak
```

### 8-3. 관제 스크립트 실행 및 누적 로그 확인
```text
agent-admin@03fbe9ff8e40:~/agent-app$ ./bin/monitor.sh
====== SYSTEM MONITOR RESULT ======
Time: 2026-10-05 00:44:24

[HEALTH CHECK]
Process 'agent-app-leak'... [OK] (PID: 273)
Port 15034... [OK]

[PROCESS RESOURCE MONITORING]
CPU (process)  : 0.0%
MEM (process)  : 2MB (0.0%)
DISK (avail)   : 398G  (used: 1%)
Firewall       : inactive

[THREAD INFO]
Thread count   : 1
    273     273 S+    0.0  0.0

[WARNING] Firewall is inactive!
[INFO] Log appended: /var/log/agent-app/monitor.log
====================================

agent-admin@03fbe9ff8e40:~/agent-app$ cat /var/log/agent-app/monitor.log
[2026-10-05 00:44:24] PROCESS:agent-app-leak PID:273 CPU:0.0% MEM:2MB(0.0%) DISK:398G FIREWALL:inactive
[2026-10-05 00:52:08] PROCESS:agent-app-leak PID:273 CPU:0.0% MEM:0MB(0.0%) DISK:398G FIREWALL:inactive
[2026-10-05 00:56:52] PROCESS:agent-app-leak PID:273 CPU:0.0% MEM:1MB(0.0%) DISK:398G FIREWALL:inactive
```

### 8-4. 데드락 정상 종료 확인
```text
2026-10-05 00:58:12,370 [INFO] User interrupted process. Shutting down gracefully...

agent-admin@03fbe9ff8e40:~/agent-app$ ps -e
    PID TTY          TIME CMD
      1 pts/0    00:00:00 bash
    269 pts/0    00:00:00 su
    270 pts/0    00:00:00 sh
    277 pts/1    00:00:00 bash
    285 pts/1    00:00:00 su
    286 pts/1    00:00:00 sh
    323 pts/1    00:00:00 bash
    433 pts/1    00:00:00 ps
```
프로세스가 정상적으로 종료되어 잔여 좀비/데드락 프로세스 없이 정리 완료됨을 확인하였습니다.

