# Docker Compose Manager

로컬 vLLM과 BGE-M3 임베딩 서비스를 쉽게 관리하기 위한 bash 스크립트입니다.

## 설치

`.bashrc` 에 다음 alias 가 이미 추가되어 있습니다:
```bash
alias dcm="$HOME/local-claude-code/docker-compose-manager.sh"
```

적용하려면:
```bash
source ~/.bashrc
```

## 사용법

```bash
dcm <command> [config] [options]
```

### Commands

| Command | Description |
|---------|-------------|
| `up`    | 서비스 시작 |
| `down`  | 서비스 중지 |
| `status`| 서비스 상태 확인 |
| `restart`| 서비스 재시작 |
| `logs`  | 로그 보기 |
| `ps`    | 실행 중인 컨테이너 목록 |
| `model` | LLM + TEI 인코더 전체 스택 관리 (LLM도 재시작됨) |
| `encoders` | TEI 인코더(BGE-M3 + BGE-reranker)만 관리 — LLM 컨테이너는 절대 건드리지 않음 |
| `help`  | 도움말 표시 |

### Configs

| Config | File | Description |
|--------|------|-------------|
| `default` | `docker-compose.yml` | 공식 vLLM nightly 이미지 (Qwen3-Coder-Next-FP8) |
| `qwen35-122b` | `docker-compose.qwen35-122b.yml` | 로컬 이미지 (Qwen3.5-122B hybrid INT4+FP8) |
| `qwen38-27b` | `docker-compose.qwen38-27b.yml` | 공식 Qwen3.8-27B BF16 |
| `qwen38-flash-next` | `docker-compose.qwen38-flash-next.yml` | Qwen3.8-Flash-Next NVFP4 + PLE NVMe 오프로딩 |

## Examples

### 서비스 시작/중지
```bash
# 기본 config 로 서비스 시작
dcm up

# qwen35-122b config 로 서비스 시작
dcm up qwen35-122b

# Qwen3.8-27B를 text-only 모드로 시작 (기본값)
dcm up qwen38-27b

# Qwen3.8-27B의 vision encoder를 함께 로드
dcm up qwen38-27b --vision

# 최초 1회: Flash-Next 런타임 빌드 및 약 170GB 체크포인트 다운로드
dcm setup qwen38-flash-next

# Flash-Next 시작 (기본값: 이미지/비디오 입력 활성화)
dcm up qwen38-flash-next

# Flash-Next를 text-only로 시작
dcm up qwen38-flash-next --text-only

# 서비스 중지
dcm down

# 특정 config 중지
dcm down qwen35-122b
dcm down qwen38-27b
dcm down qwen38-flash-next
```

### LLM + BGE 인코더 상시 서빙

> **먼저 알아둘 것:** 이 저장소를 사용하는 대화형 에이전트 세션 자체가
> `vllm-local-coder` 컨테이너가 서빙하는 vLLM 위에서 동작합니다. 따라서 LLM
> 서비스를 수렴(up/down/restart)하는 명령은 곧 자기 세션을 종료시키는 명령입니다.
> 인코더만 다루려면 반드시 `dcm encoders`를 사용하고, `dcm model up|down`은
> LLM까지 재시작 의도가 명시적인 경우에만 사용합니다.

Maple Chat처럼 생성 모델과 vector embedding 모델이 동시에 필요한 경우에는
`model` 하위 명령을 사용합니다. `model up`은 **LLM을 먼저 시작하고 readiness를
확인한 다음** 별도의 BGE-M3 TEI 서버를 시작합니다. 이 순서는 메인
vLLM이 먼저 자신의 메모리 예산을 확보하도록 하기 위한 것입니다.

```bash
# 현재 사용 중인 Qwen3.8 Flash-Next + BGE-M3 시작
dcm model up qwen38-flash-next --vision

# 두 모델의 컨테이너 상태 / 통합 로그 확인
dcm model status qwen38-flash-next
dcm model logs -f qwen38-flash-next

# 두 모델 모두 중지 (LLM까지 재시작되므로 주의)
dcm model down qwen38-flash-next
```

인코더만 다루려면 `encoders`를 사용합니다.

```bash
# BGE-M3 + BGE-reranker-v2-m3 만 시작/재창출 (LLM은 무변경)
dcm encoders up
dcm encoders restart

# 컨테이너 상태 + 실제 연산 백엔드(CUDA vs CPU 강등) + 호스트 메모리 여유
dcm encoders status

# /info attestation, /v1/embeddings, /rerank 실계약 검증
dcm encoders validate

# Maple Chat의 실제 rerank 부하 형태(30 doc x ~600 token) 재현
dcm encoders probe

# 인코더만 중지 (Compose project dcm-model-plane 내부만 수렴)
dcm encoders down
```

#### Compose project 격리 (왜 `encoders`가 별개로 존재하는가)

`docker-compose.embedding.yml`은 top-level `name: dcm-model-plane`로 자기
Compose project를 격리합니다. 격리 이전에는 LLM 파일과 같은 project
(`local-claude-code`)를 공유했기 때문에, embedding 파일에 대한
`docker compose down`이 **같은 project의 `vllm-local-coder`까지 중지**시켰습니다.
`--remove-orphans`는 더 위험했습니다. `encoders_compose()`는 모든 호출에서
`-p dcm-model-plane`을 고정하고 LLM Compose 파일을 아예 로드하지 않으므로,
LLM 컨테이너가 서비스로도 orphan으로도 수렴될 수 없습니다. 이 계약은
`tests/test-model-stack.sh`가 잠급니다(모든 encoder 호출의 `-p` 고정,
`encoders *` 의 어떤 하위 명령도 LLM 파일을 참조하지 않음).

API는 기본적으로 loopback에만 노출됩니다.

- 생성 LLM: 기존 profile 주소 유지 (`qwen38-*`는 `http://127.0.0.1:8001/v1`)
- BGE-M3 embedding: `http://127.0.0.1:8081/v1/embeddings` (별칭 `bge-m3`, 1024차원)
- BGE-reranker-v2-m3: `http://127.0.0.1:8082/rerank` (별칭 `bge-reranker-v2-m3`)

reranker는 TEI 1.9에서 주의해서 다뤄야 합니다. 타입은 모델 아키텍처에서
자동 추론되며 `--reranker` 플래그가 없습니다. rerank 엔드포인트는 origin root의
`POST /rerank`이고 응답은 **정렬된 `[{index,score}]` 맨 배열**이며
`/v1/rerank`는 404입니다. `GET /info`가 `model_id`/`model_sha`(=revision)와
`model_type.reranker`를 돌려주므로 attestation에 사용합니다.

Docker 안의 클라이언트는 `http://dcm-embedding:80/v1`,
`http://dcm-reranker:80`을 사용합니다.

호스트에서 실행하는 클라이언트는 위 loopback 주소를 사용합니다. Docker에서
실행하는 Maple Chat은 `dcm-model-plane` 외부 네트워크에 연결한 뒤 위 네트워크
별칭을 사용합니다. 따라서 TEI 포트를 LAN 전체에 노출하지 않고도 두 Compose
프로젝트가 통신할 수 있습니다. 이 네트워크는 `dcm encoders up`(또는
`dcm model up`)이 인코더를 시작할 때 생성됩니다.

#### reranker 배치 사이징: 429의 실제 원인

`--max-batch-tokens`를 작게 걸면 요청이 밀려도 안전할 것처럼 보이지만, 실제
Maple Chat rerank 요청은 `rerank_limit=30` 후보 × chunk target 550 / max 700
token, 즉 **한 요청에 약 18k token**입니다. 4096으로 두고 실측한 결과:

| 요청 형태 | 결과 |
|-----------|------|
| `POST /rerank` 4 doc × 200 token | 200 OK, 202 ms |
| 30 doc admitted (실측 로그) | `inference_time=9.9 ms`, `total_time=17.5 ms` |
| `POST /rerank` 30 doc × ~600 token | **429 `{"error":"Model is overloaded"}`** |
| `/v1/embeddings` 1 doc | 200 OK, warm 141 ms |
| `/v1/embeddings` 32 doc × ~600 token | 200 OK, 1308 ms |
| `/v1/embeddings` 64 doc | 422 `batch size 64 > maximum allowed batch size 32` |

원인은 GPU 부족이 아니라 TEI의 배치/permit 포화였습니다. 그래서 reranker
기본값을 `DCM_RERANKER_MAX_BATCH_TOKENS=20480`(실 요청 1회 분량)으로 올렸습니다.
임베딩 쪽은 client batch 상한이 32이므로, 한 요청에 32개를 넘기면 4096이 아니라
**422**로 실패합니다. 클라이언트 쪽 배치 분할은 Maple Chat의 몫입니다.

간단한 embedding 확인 요청:

```bash
curl http://127.0.0.1:8081/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"bge-m3","input":["메이플스토리 장비 강화"]}'
```

#### GB10 메모리 정책

기존 LLM Compose 파일의 `--gpu-memory-utilization` 값(0.70~0.90)은 변경하지
않습니다. BGE-M3는 GB10/sm_121용 공식 TEI 1.9 multi-arch 이미지를 digest로
고정하고, checkpoint commit
`5617a9f61b028005a4858fdac845db406aefb181`, FP16, CLS pooling,
최대 길이/배치 token 8192, 최대 batch request 16, 최대 동시 request 32로
제한합니다. 생성 서버와 달리 TEI encoder는 별도 KV cache를 예약하지 않습니다.

이 제한도 GB10 통합 메모리에서의 실제 동시 적재를 보장하지는 않습니다.
`model up`은 `/health`, `/info`의 model/commit, 그리고 실제 1024차원 정규화
embedding 응답까지 검증합니다. 실패하면 embedding 컨테이너만 중지하고 이미
정상인 LLM은 유지합니다. 실제 동시 서빙은 다음으로 확인합니다.

```bash
nvidia-smi
dcm model status qwen38-flash-next
curl -fsS http://127.0.0.1:8001/health
curl -fsS http://127.0.0.1:8081/health
curl -fsS http://127.0.0.1:8081/info
```

호스트 상황에 따라 embedding batch/concurrency를 더 낮출 수 있습니다. 변경 후
두 health endpoint와 실제 embedding 요청을 확인해야 합니다.

```bash
DCM_EMBEDDING_MAX_BATCH_TOKENS=8192 \
DCM_EMBEDDING_MAX_BATCH_REQUESTS=8 \
DCM_EMBEDDING_MAX_CONCURRENT_REQUESTS=16 \
  dcm model up qwen38-flash-next --vision
```

GB10은 `nvidia-smi`에 메모리 합계를 `N/A`로 보고하기 때문에 통합 메모리 usage를
직접 읽을 수 없습니다. 대신 `dcm encoders status`가 (1) TEI 로그에서 실제
백엔드(`Starting FlashBert model on Cuda(...)` vs `Using CPU instead`),
(2) `/proc/meminfo`의 `MemAvailable`을 드러냅니다. TEI는 CUDA 컨텍스트를
못 얻으면 **조용히 CPU로 강등**되고, 상시 서빙 전제가 무너집니다.
`MemAvailable`이 8 GiB 아래로 떨어지면 같은 강등이 일어나기 전의 신호입니다.
실측 점유는 embedding 약 1368 MiB, reranker 약 1370 MiB이며 vLLM의
`--gpu-memory-utilization 0.75`(약 97 GiB)는 그대로 유지됩니다.

대규모 색인 재구축이나 학습처럼 GPU를 독점해야 하는 작업에서는 기존
`dcm gpu-job run -- ...`을 그대로 사용합니다. dual-model stack이 실행 중이면
래퍼가 embedding을 먼저, LLM을 다음으로 정지하고, 작업 후에는 LLM을 먼저
복구한 다음 embedding을 복구합니다.

### Qwen3.8-Flash-Next 설정

Qwen3.8-Flash-Next는 텍스트, 이미지 및 비디오 입력을 지원합니다. 단일 GB10의
128GB 통합 메모리에 맞추기 위해 routed experts는 NVFP4 체크포인트를 사용하고,
51B N-gram embedding(PLE)은 품질 보존을 위해 BF16으로 유지하고 NVMe에서 mmap으로 읽습니다.
런타임은 blazux의 직접 mmap/정확한 top-k/prefix-cache 수정 위에
dolf3131의 단일 GB10 TP1 skinny-GEMM 패치를 고정 커밋으로 결합합니다. 따라서
dolf 원본 방식처럼 별도의 128GB swap 파일에 PLE를 다시 기록하지 않으면서도
TP1 decode 최적화를 사용합니다.

최초 설정에는 체크포인트 약 170GB와 Docker 이미지 공간이 필요합니다.

```bash
dcm setup qwen38-flash-next
dcm up qwen38-flash-next       # vision 기본 활성화
dcm logs -f qwen38-flash-next  # 최초 로드는 약 8~15분
```

API 주소와 모델 별칭은 27B 구성과 동일합니다.

- API: `http://127.0.0.1:8001/v1`
- Anthropic 호환 base URL: `http://127.0.0.1:8001`
- 모델 별칭: `local-coder`

따라서 아래 Claude Code 환경 설정을 변경하지 않고 두 프로필을 전환할 수
있습니다. 두 모델은 동일한 GPU와 컨테이너 이름을 사용하므로 동시에 실행하지
않습니다.

이미지 분석은 OpenAI 호환 API의 `image_url` content 형식을 사용합니다.

```bash
curl http://127.0.0.1:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "local-coder",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "이 이미지에 무엇이 보이는지 설명해줘."},
        {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
      ]
    }],
    "max_tokens": 512
  }'
```

메모리가 더 필요한 텍스트 작업은 다음처럼 vision encoder를 제외할 수 있습니다.

```bash
dcm restart qwen38-flash-next --text-only
dcm restart qwen38-flash-next --vision
```

### Qwen3.8-27B Vision 설정

Qwen3.8-27B API는 기존 로컬 서비스의 8000 포트와 충돌하지 않도록
`http://127.0.0.1:8001/v1`에서 실행됩니다.

Qwen3.8-27B는 이미지와 비디오를 처리할 수 있는 vision encoder를 포함합니다.
코딩이나 텍스트 생성만 사용할 때는 vision encoder를 제외하여 모델 메모리를
KV cache에 더 사용할 수 있습니다.

```bash
# Text-only: --language-model-only 적용 (기본값)
dcm up qwen38-27b
dcm up qwen38-27b --text-only

# Vision: vision encoder 로드
dcm up qwen38-27b --vision

# 실행 중인 모드를 바꾸면서 컨테이너 재생성
dcm restart qwen38-27b --vision
dcm restart qwen38-27b --text-only
```

옵션 없이 `restart`하면 현재 컨테이너의 모드를 그대로 유지합니다. 모드를
변경하려면 `--vision` 또는 `--text-only`를 지정해야 합니다.

### 상태 확인
```bash
# 서비스 상태 확인
dcm status

# 실행 중인 vllm 컨테이너 목록
dcm ps
```

### 로그 보기
```bash
# 마지막 로그 출력
dcm logs

# 로그 실시간 추적
dcm logs -f

# 마지막 50 줄 출력
dcm logs -n 50

# 특정 config 의 로그 추적
dcm logs -f qwen35-122b
dcm logs -f qwen38-27b
dcm logs -f qwen38-flash-next
```

## Claude Code에서 Qwen3.8 사용

vLLM의 Anthropic Messages 호환 API를 통해 Claude Code를 Qwen3.8-27B 또는
Qwen3.8-Flash-Next에 직접 연결할 수 있습니다. Qwen3.8 서비스는 `8001` 포트, 모델 별칭은
`local-coder`를 사용합니다.

`~/.claude/settings.json`의 `env`에 아래 값을 설정합니다. 로컬 vLLM은 실제
Anthropic 인증을 사용하지 않지만 Claude Code가 요구하므로 임의의 비밀이 아닌
dummy 값을 사용합니다.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8001",
    "ANTHROPIC_API_KEY": "local-vllm",
    "ANTHROPIC_AUTH_TOKEN": "local-vllm",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "local-coder",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "local-coder",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "local-coder",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

서비스와 연결을 확인한 뒤 Claude Code를 실행합니다.

```bash
dcm status qwen38-27b
curl http://127.0.0.1:8001/v1/models
claude --model local-coder
```

현재 Claude Code 2.1.144와 vLLM nightly 조합에서는 `claude -p`의 단순 응답은
정상 출력되지만, tool call이 포함되면 도구 실행과 최종 응답이 세션 기록에
남아도 stdout이 비어 있을 수 있습니다. 이 경우 대화형 `claude` 실행을 권장합니다.

Claude Code는 이미지 입력보다 코드 에이전트의 텍스트 및 tool calling이
중심이므로 `--text-only` 모드로도 사용할 수 있습니다. 별도의 OpenAI 호환
클라이언트에서 이미지 입력까지 처리하려면 `--vision` 모드로 실행합니다.
Flash-Next 프로필은 `--vision`이 기본값이고, 27B 프로필은 `--text-only`가
기본값입니다.

Flash-Next는 thinking과 preserved thinking을 기본 활성화합니다. 일반 채팅처럼
thinking이 필요하지 않은 개별 OpenAI 호환 요청에서는 다음 값을 추가해 끌 수
있습니다.

```json
{
  "chat_template_kwargs": {
    "enable_thinking": false
  }
}
```

## Pi Agent 연결

[`earendil-works/pi`](https://github.com/earendil-works/pi)의 coding agent가 사용자
범위에 설치되어 있으며, 기본 모델은 `local-vllm/local-coder`입니다.

```bash
# 현재 디렉터리에서 대화형 coding agent 시작
pi

# vLLM /health를 먼저 확인하고 로컬 Qwen + high thinking으로 시작
pi-local

# 최근 세션 계속하기 / 세션 선택하기
pi -c
pi -r
```

설정 파일은 다음 위치에 있습니다.

- `~/.pi/agent/models.json`: `http://127.0.0.1:8001/v1`, OpenAI Chat
  Completions, 262K context, text+image, Qwen chat-template thinking
- `~/.pi/agent/settings.json`: 기본 provider/model과 `high` thinking
- `~/.pi/agent/AGENTS.md`: CUDA 파인튜닝은 `dcm gpu-job run -- ...`을 사용하도록
  하는 전역 GPU 스케줄링 규칙

Pi의 `qwen-chat-template` 호환 모드는 요청마다
`chat_template_kwargs.enable_thinking`과 `preserve_thinking`을 전달합니다. 따라서
서버 기본값과 무관하게 Pi에서는 thinking이 자동 활성화되고, multi-turn tool call에
이전 thinking을 다시 전달할 수 있습니다.

Flash-Next를 vision 모드로 실행한 뒤에는 이미지를 파일로 직접 첨부할 수 있습니다.

```bash
dcm up qwen38-flash-next --vision
pi-local -p @screenshot.png "이 화면을 분석해줘"
```

현재 실행 중인 컨테이너가 `--language-model-only`이면 Pi에 이미지 기능이 표시되어도
실제 이미지 요청은 실패합니다. Flash-Next 프로필은 기본이 vision 모드입니다.
Pi 세션은 `~/.pi/agent/sessions/`에 JSONL로 자동 저장되므로 vLLM 컨테이너를
정지·재시작해도 `pi -c`로 대화를 이어갈 수 있습니다.

## 파인튜닝용 GPU 독점 작업

이미지 생성 모델 파인튜닝처럼 GPU 통합 메모리를 크게 사용하는 작업은 vLLM과
동시에 실행하지 말고 `gpu-job` 래퍼를 사용합니다.

```bash
# 현재 요청이 끝날 때까지 기다린 뒤 vLLM을 내리고 학습 실행
dcm gpu-job run -- ./train_lora.sh

# Docker Compose 기반 학습도 반드시 foreground로 실행
dcm gpu-job run -- docker compose -f finetune.yml up --abort-on-container-exit

# 작업 상태 / 비정상 종료 후 복구
dcm gpu-job status
dcm gpu-job recover
```

래퍼는 `vllm:num_requests_running`과 `vllm:num_requests_waiting`이 0이 될 때까지
기다리고, 실행 중인 `dcm-embedding-bge-m3`와 `vllm-local-coder` 컨테이너를
정지한 다음 학습 명령을 실행합니다. 학습이 성공하거나 실패하거나
`SIGINT`/`SIGTERM`으로 중단되어도 이전에 실행 중이던 동일한 컨테이너만 원래
순서대로 다시 시작하고 각 `/health`가 응답할 때까지 기다린 후 종료합니다.
동시에 여러 GPU 작업이 실행되지 않도록 `flock` 잠금을 사용합니다.

vLLM의 KV/prefix cache 자체는 정지 시 사라집니다. Claude Code 및 Pi의 로컬 대화
기록이나 API 클라이언트가 보관한 `messages`는 그대로이므로 재기동 후 문맥은
복원되지만, 첫 요청은 전체 문맥을 다시 prefill해야 합니다. Pi가 이 래퍼를 bash
tool로 실행하면 학습과 vLLM 복구가 끝날 때까지 tool call이 대기한 다음 같은 세션의
다음 turn을 보냅니다. 학습 명령이 백그라운드로 빠지면 vLLM이 너무 일찍
재시작되므로 명령은 반드시 foreground에 머물러야 합니다.

다시 Anthropic API를 사용하려면 `~/.claude/settings.json`에서 위의
`ANTHROPIC_*` 로컬 설정을 제거하거나 기존 값으로 복원합니다.

## Environment Variables

| Variable | Description | Used by |
|----------|-------------|---------|
| `HF_TOKEN` | Hugging Face API 토큰 | Qwen 모델 다운로드가 필요한 config |
| `DCM_EMBEDDING_IMAGE` | embedding용 GB10/arm64 TEI 이미지 | `dcm model` |
| `DCM_EMBEDDING_MODEL` | embedding checkpoint (기본 `BAAI/bge-m3`) | `dcm model` |
| `DCM_EMBEDDING_MODEL_REVISION` | immutable checkpoint revision | `dcm model` |
| `DCM_EMBEDDING_MODEL_ALIAS` | API 모델 별칭 (기본 `bge-m3`) | `dcm model` |
| `DCM_EMBEDDING_PORT` | loopback host port (기본 `8081`) | `dcm model`, `gpu-job` |
| `DCM_EMBEDDING_MAX_BATCH_TOKENS` | TEI batch token 상한 (기본 `8192`) | `dcm model` |
| `DCM_EMBEDDING_MAX_BATCH_REQUESTS` | TEI batch request 상한 (기본 `16`) | `dcm model` |
| `DCM_EMBEDDING_MAX_CLIENT_BATCH_SIZE` | 요청 1건의 input 개수 상한 (기본 `16`) | `dcm model` |
| `DCM_EMBEDDING_MAX_CONCURRENT_REQUESTS` | 동시 요청 상한 (기본 `32`) | `dcm model` |
| `DCM_MODEL_READY_TIMEOUT` | 각 모델 readiness 제한 초 (기본 `1800`) | `dcm model up` |

설정 예시:
```bash
export HF_TOKEN="hf_your_token_here"
```

## 도움말 보기

```bash
dcm h
dcm -h
dcm help
docker-compose-manager.sh -h
```
