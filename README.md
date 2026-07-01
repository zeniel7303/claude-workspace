# claude-workspace

Claude Code 설정, 작업 문서, AI 메모리를 여러 기기에서 동기화하기 위한 workspace 레포.

각 프로젝트의 `.claude/`, `dev/`, `CLAUDE.md`, Claude 메모리는 public 레포에 포함되지 않고 이곳에서 관리된다.  
git hooks를 통해 커밋할 때 자동으로 업로드되고, pull할 때 자동으로 복원된다.

---

## 구조

```
claude-workspace/
├── CLAUDE.md                  # 모든 프로젝트에 공통으로 적용되는 룰
├── hooks/
│   ├── sync.sh                # post-commit 훅 — 프로젝트 → workspace 동기화
│   └── restore.sh             # post-merge 훅 — workspace → 프로젝트 복원
└── [ProjectName]/
    ├── CLAUDE.md              # 프로젝트 전용 룰
    ├── setup.sh               # 새 기기 셋업 스크립트
    ├── claude/                # .claude/ 디렉토리 백업 (명령어, 에이전트, 훅 등)
    ├── dev/                   # 작업 문서 (plan, context, tasks)
    └── memory/                # Claude AI 메모리
```

---

## 동작 원리

```
[프로젝트에서 git commit]
    → post-commit 훅 실행
    → hooks/sync.sh: .claude/ + dev/ + 메모리를 workspace에 복사
    → workspace에 자동 커밋 & push

[프로젝트에서 git pull]
    → post-merge 훅 실행
    → hooks/restore.sh: workspace에서 .claude/ + dev/ + 메모리 복원
```

두 PC에서 작업하는 경우, 커밋과 풀만 해도 Claude 환경이 자동으로 맞춰진다.

---

## 새 기기 셋업

각 프로젝트 레포에 포함된 `setup-claude.sh`를 실행하면 된다.

```bash
# 프로젝트 레포 루트에서 1회 실행
bash setup-claude.sh
```

내부적으로 아래 작업을 자동으로 처리한다.

1. 이 레포(`claude-workspace`) 클론
2. `git config --global claude.workspace` 등록
3. `.claude/`, `dev/`, `CLAUDE.md`, 메모리 복원
4. post-commit / post-merge 훅 설치

---

## 공통 CLAUDE.md

`claude-workspace/CLAUDE.md`는 연결된 모든 프로젝트에 자동으로 적용되는 공통 룰을 담고 있다.  
`setup-claude.sh` 실행 시 프로젝트 전용 룰과 합쳐져 프로젝트 루트의 `CLAUDE.md`로 생성된다.

### 거버넌스 룰

| 룰 | 내용 |
|----|------|
| **계획 먼저** | 코드 작성 전 구현 계획을 세우고 사용자 컨펌을 받는다. 승인 전까지 구현하지 않는다. |
| **커밋 금지** | Claude가 직접 `git commit`을 실행하지 않는다. 커밋 메시지만 제안하고 실제 커밋은 사용자가 직접. 사용자가 명시적으로 "커밋해줘"라고 요청한 경우만 예외. |
| **Co-Authored-By 금지** | 커밋 메시지에 `Co-Authored-By: Claude ...` 줄을 절대 추가하지 않는다. |
| **push 금지** | 사용자가 명시적으로 요청하지 않는 한 push하지 않는다. |

### 작업 워크플로우

모든 코드 작업은 아래 흐름을 따른다.

```
사용자가 새 작업 요청
        │
        ▼
[RULE 1] /dev-docs 실행
  → dev/active/[작업명]/ 디렉토리 생성
  → plan.md / context.md / tasks.md 작성
  → 사용자에게 계획 컨펌
        │
        ▼
     구현 진행
        │
        ▼
[RULE 2] 파일 수정 완료 후
  → /dev-docs-update 실행 (작업 문서 최신화)
  → 코드 리뷰 에이전트 실행
        │
        ▼
     작업 완료
```

### 코드 리뷰 에이전트

작업 완료 후 아래와 같이 `general-purpose` 에이전트에 `code-architecture-reviewer` 페르소나를 넘겨 코드 리뷰를 실행한다.

```python
Agent(
    subagent_type="general-purpose",
    prompt="You are a code-architecture-reviewer. 이 세션에서 작성/수정된 코드를 리뷰해줘. 활성 작업 문서는 dev/active/ 에 있음."
)
```

> **주의**: `.claude/agents/`에 정의된 에이전트(`code-architecture-reviewer` 등)는 Claude Code에 `subagent_type`으로 직접 등록되지 않는다.  
> 반드시 `subagent_type="general-purpose"`를 사용하고 프롬프트 안에 페르소나를 포함해야 한다.

### 수정 방법

공통 룰을 수정하려면 `claude-workspace/CLAUDE.md`를 직접 편집한 뒤 각 프로젝트에서 `setup-claude.sh`를 재실행하면 된다.

---

## 새 프로젝트 추가하는 법

**1. workspace에 프로젝트 디렉토리 생성**

기존 프로젝트 디렉토리를 복사해서 `PROJECT_KEY`만 변경하는 게 가장 빠르다.

```bash
cp -r ExistingProject NewProject
# NewProject/setup.sh 열어서 PROJECT_KEY="NewProject" 로 수정
# NewProject/CLAUDE.md 열어서 프로젝트 전용 룰 작성
```

**2. 프로젝트 레포에 `setup-claude.sh` 추가**

```bash
#!/bin/bash
WORKSPACE_URL="https://github.com/zeniel7303/claude-workspace"
WORKSPACE_PATH="${1:-$(dirname "$(git rev-parse --show-toplevel)")/claude-workspace}"
PROJECT_DIR="$(git rev-parse --show-toplevel)"
[ -d "$WORKSPACE_PATH/.git" ] || git clone "$WORKSPACE_URL" "$WORKSPACE_PATH"
bash "$WORKSPACE_PATH/NewProject/setup.sh" "$PROJECT_DIR"
```

**3. 프로젝트 레포 `.gitignore`에 추가**

```
# Claude (claude-workspace 레포로 별도 관리)
.claude/
CLAUDE.md
dev/
```

---

## CLAUDE.md 수정 방법

| 수정 대상 | 파일 위치 |
|-----------|-----------|
| 모든 프로젝트에 적용할 공통 룰 | `claude-workspace/CLAUDE.md` |
| 특정 프로젝트에만 적용할 룰 | `claude-workspace/[ProjectName]/CLAUDE.md` |

수정 후 해당 프로젝트에서 `setup-claude.sh`를 재실행하면 두 파일이 합쳐져 프로젝트 루트의 `CLAUDE.md`가 갱신된다.

> 프로젝트 루트의 `CLAUDE.md`는 자동 생성 파일이므로 직접 편집해도 재실행 시 덮어씌워진다.
