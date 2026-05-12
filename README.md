# ai-management-bar

> macOS 메뉴 막대에서 여러 Claude Code 세션을 한눈에 보고, AFK 사이에 자동 요약된 맥락으로 빠르게 따라잡는 도구.

## 목표

이 도구가 해결하려는 두 가지 문제:

1. **더 편한 Claude Code 탭 관리** — iTerm2 의 여러 탭에 띄워둔 Claude Code 세션을 메뉴 막대 한 곳에서 보고, 행 클릭으로 해당 탭으로 즉시 이동. 상태(작업 중 / 입력 대기 / 완료)도 한눈에.
2. **한눈에 빠르게 모든 AI 작업 맥락 파악** — 각 세션이 지금 어디서 무얼 하고 있는지 (cwd · git branch · 작업 요약) 표시. 사용자가 자리를 5분 이상 비우면 백그라운드에서 `claude` CLI 가 한국어 두 문장 recap 을 미리 만들어둠 → 돌아왔을 때 대기 시간 0초.

## 한눈에 보기

```
●  Claude Code (3)
─────────────────────────────────────────────────
🔵 🟢  ~/WorkSpace/my-wiki  ·  main          running    ▶
       노트 정리 스크립트 리팩토링
─────────────────────────────────────────────────
   🟡  ~/WorkSpace/fleet-deploy  ·  feat/x   waiting    ▶
       Bash 실행 허가 필요
─────────────────────────────────────────────────
   ✅  ~/WorkSpace/docs-update  ·  main      done       ▶
       PR #423 완료
─────────────────────────────────────────────────
```

`▶ chevron` 펼침 시 패널:

```
🌀 자동 recap (2분 전)
   글로벌 CLAUDE.md 의 비효과 규칙을 정리해 행동·협업 중심으로 축약했다.
   my-wiki 의 CLAUDE.md 에서 wiki 운영 규칙 검증이 남았다.

📋 Compact recap          ← Claude Code 가 컨텍스트 한도 시 자동 생성한 요약 (있을 때만)
   Summary: 1. Primary Request: ...

📍 위치
   src/api.py (마지막 편집)
   ~/WorkSpace/my-wiki · main
─────────────────────────────────────────────────
[복사]  [iTerm 탭]
```

메뉴바 아이콘은 **상태 인식**:
- 전부 idle/done → 회색 outline bubble
- 하나라도 running → 채워진 bubble
- 하나라도 waiting → **주황 ⚠️ bubble** (시선 끔)

## 동작 원리

```
┌──────────────────────────┐    파일/이벤트     ┌──────────────────────────┐
│  Claude Code 세션 (iTerm │ ───────────────▶  │   SwiftUI MenuBarExtra   │
│  tab N)                  │   상태 JSON       │   앱 (단일 프로세스)      │
│                          │                   │                          │
│  lifecycle hooks         │                   │  • FSEvents 폴더 감시    │
│  (SessionStart, Stop, …) │                   │  • 행 클릭 → iTerm2 탭   │
│                          │                   │  • AFK 5분 → claude CLI  │
│                          │                   │    recap (background)    │
└──────────────────────────┘                   └──────────────────────────┘
```

3 가지 컴포넌트:

1. **Hook 스크립트** (`~/.claude/menubar/bin/hook.py`)
   - Claude Code 가 lifecycle event 마다 stdin 으로 JSON 페이로드 전송
   - 상태 파일 `~/.claude/menubar/sessions/<session_id>.json` 갱신
2. **상태 디렉터리** — 세션 1개당 파일 1개 (단일 진실 소스)
3. **SwiftUI MenuBarExtra 앱**
   - 상태 디렉터리를 FSEvents 로 감시 → 변경 즉시 UI 갱신
   - 10초 polling 마다 AFK 5분 + transcript 갱신 감지 → background `claude` CLI 호출
   - 행 클릭 → `osascript` 로 iTerm2 탭 활성화 (`ITERM_SESSION_ID` 매핑)

## 설치 / 실행

### 1. 의존성

```sh
xcode-select --install   # Swift toolchain (이미 있으면 skip)
which claude             # Claude Code CLI 가 PATH 에 있어야 자동 recap 동작
```

### 2. 빌드 & 실행 (이 한 줄이면 끝)

```sh
cd app
swift build -c release
./.build/release/ClaudeMenubar
```

앱 시작 시 자동으로:

1. `~/.claude/menubar/bin/hook.py` + `transcript_signals.py` 디스크에 생성
2. `~/.claude/settings.json` 백업 후 hooks 섹션에 안전 머지 (다른 도구 hook 보존)
3. 메뉴 막대에 아이콘 표시 + 활성 세션 자동 발견

첫 실행 시 macOS 가 iTerm2 자동화 권한을 한 번 묻습니다. 허용해야 행 클릭 → 탭 전환 동작.

### 3. 부팅 시 자동 실행 (선택)

시스템 설정 → 로그인 항목에 빌드된 binary 추가.

## 자동 recap 정책

**트리거**: transcript jsonl 의 mtime 이 `now - 5분` 이전 (AFK 판단). 마지막 recap 이후 transcript hash 가 변했을 때만 호출.

**한 번만 정책**: 생성 후 추가 활동 없으면 재호출 안 함. 새 활동 시작 → 다시 5분 quiet 대기.

**비용**: 사용자의 Claude 구독 quota 차감 (`--model haiku` 기본).

**대기 시간**: 사용자가 dropdown 열 때 0초. 호출은 백그라운드에서 미리 끝나 있음.

## 파일 구조

```
.
├── hook/
│   ├── hook.py                 ← 정본
│   ├── transcript_signals.py   ← jsonl 신호 추출 (마지막 편집·compact recap)
│   ├── test_hook.py
│   └── test_transcript_signals.py
├── app/                        ← Swift Package Manager
│   ├── Package.swift
│   └── Sources/ClaudeMenubar/
│       ├── ClaudeMenubarApp.swift    ← @main · MenuBarExtra
│       ├── SessionState.swift
│       ├── SessionStore.swift        ← FSEvents · polling · patch
│       ├── SessionRowView.swift      ← row · chevron · expand
│       ├── ReentryBriefView.swift    ← brief 패널
│       ├── ITermActivator.swift      ← osascript iTerm2 탭 활성화
│       ├── ClaudeRecapGenerator.swift ← AFK 자동 recap
│       ├── HookInstaller.swift       ← settings.json 안전 머지
│       ├── SessionDiscovery.swift    ← 앱 시작 전 떠 있던 세션 발견
│       └── EmbeddedHookSource.swift  ← hook 임베드 사본 (앱 단독 동작용)
└── scripts/
    └── install.sh              ← CLI 로 hook 등록 (선택)
```

## 개발

### Python 단위 테스트

```sh
python3 hook/test_hook.py
python3 hook/test_transcript_signals.py
```

### hook.py 정본 ↔ Swift 임베드 동기화 검증

`hook/hook.py` 와 `hook/transcript_signals.py` 가 정본이며, `app/Sources/ClaudeMenubar/EmbeddedHookSource.swift` 의 raw string 으로 임베드되어 앱이 단독 배포 가능합니다. 수정 시 둘 다 같이 갱신:

```sh
# hook.py 동기화 확인
diff <(python3 -c "import re; s=open('app/Sources/ClaudeMenubar/EmbeddedHookSource.swift').read(); m=re.search(r'hookSource: String = #\"\"\"\n(.*?)\n\"\"\"#', s, re.S); print(m.group(1))") hook/hook.py

# transcript_signals.py 동기화 확인
diff <(python3 -c "import re; s=open('app/Sources/ClaudeMenubar/EmbeddedHookSource.swift').read(); m=re.search(r'transcriptSignalsSource: String = #\"\"\"\n(.*?)\n\"\"\"#', s, re.S); print(m.group(1))") hook/transcript_signals.py
```

차이가 없으면 동기화 OK.

## 의도적으로 빼놓은 것 (YAGNI)

- iTerm2 외 터미널 지원
- 별도 dashboard 윈도우
- 원격 세션
- 세션 간 link 추적
- 진척률 % 표시 (TodoWrite 파싱)

향후 필요해지면 별도 phase 로.

## License

Personal project. 사용·수정·재배포 자유.
