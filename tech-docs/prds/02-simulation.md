# 02 - simulation

## PRD 02 — Real Simulation: End-to-End Interview

#### This document traces a complete interview session from assessor setup through to portfolio export. It is the referencesimulation for QA, integration testing, and onboarding new engineers.

## Scenario Setup

#### Role: Senior Frontend Engineer

#### Assessor: Dimas (HR lead at TechCorp)

#### Candidate: Ahmad Rizky

#### Skills configured: React/Frontend Dev (L3 expected), Communication (L3 expected), System Design (L2 expected)

#### Time limit: 45 minutes

#### Actual session duration: 38 minutes (all covered before ceiling)

## Phase 1 — Setup (Assessor, T-5 min)

```
[Dimas opens Assessor Config page]
Dimas fills form:
Role title: "Senior Frontend Engineer"Time limit: 45 minutes
Skills:1. React/Frontend Dev (from B7: SK-ENG-001)
```
(^) 2. Communication (custom skill)Expected level: L
Scope: clear technical explanation, cross-team alignment, async writingL1-L5 anchors: [Dimas fills each level]
(^) 3. System Design (custom skill)Expected level: L
Scope: frontend system architecture, scalability, component design patternsExpected level: L
Dimas clicks [Save & Create Invite Link]
→ N1: Assessment config saved (id: cfg-001)
→ N2: System prompt generated from cfg-001(skill names + scopes + L1-L5 anchors compiled into Gemini Live system prompt)
Dimas sees invite page:
Link: https://app.rakamin.com/interview/tok-abc
→ N4: Session record created{ id: sess-001, config_id: cfg-001, status: pending, invite_token: tok-abc123 }
Dimas copies link, sends to Ahmad via email

- • • • • •


## Phase 2 — Session Start (T=0:00)

```
[Ahmad opens link on laptop, sees interview page]
Ahmad reads brief: "This is a 45-minute audio interview. Click the mic to start."Ahmad clicks [Start Interview]
→ Browser requests microphone permission → granted
→ Frontend: POST /api/sessions/tok-abc123/start→ Backend: N5 opens Gemini Live WebSocket
WebSocket SETUP message sent to Gemini:
{"setup": {
"model": "gemini-2.0-flash-live","system_instruction": "<compiled system prompt from N2>",
"generation_config": {"response_modalities": ["AUDIO"],
```
(^) },"speech_config": { "voice_config": { "prebuilt_voice_config": { "voice_name": "Puck" } } }
"input_audio_transcription": {},"output_audio_transcription": {},
"context_window_compression": { "sliding_window": {} },"session_resumption": {}
(^) }}
→ Session record updated: { status: active, started_at: 2026-02-28T09:00:00Z }
INITIAL COVERAGE MAP injected as clientContent (before AI's first turn):
{"skills": [
{ "id": "sk-eng-001", "label": "React/Frontend Dev", "state": "not_yet", "probe_count": 0 },{ "id": "communication", "label": "Communication", "state": "not_yet", "probe_count": 0 },
(^) ],{ "id": "system-design", "label": "System Design", "state": "not_yet", "probe_count": 0 }
"discovered": [],"time_remaining_minutes": 45,
(^) }"priority_next": "sk-eng-001"
AI (T=0:02): "Hi Ahmad, thanks for joining today. Let's jump straight in —
tell me about the most technically challenging frontend projectyou've worked on recently."
→ N6: Turn #1 saved
{ turn: 1, speaker: "ai", text: "Hi Ahmad...", ts: 0:02 }

## Phase 3 — Live Interview (T=0:02 to T=38:00)


### Exchange 1 — React surface probe

```
T=0:02 AI: "Hi Ahmad, tell me about the most technically challenging frontend project you've worked on recently."
T=0:05 AHMAD: "At my last job we built a real-time dashboard for logistics
tracking — hundreds of concurrent updates per second. Thebiggest challenge was keeping the React state in sync without
causing performance issues."
→ N6: Turn #2 saved { turn: 2, speaker: "candidate", text: "At my last job..." }
┌─────────────────────────────────────────────────┐│ N7 ASYNC — starts immediately after Turn #2 │
│ Input: last 2 turns + coverage map ││ Gemini Flash analyzing... │
└─────────────────────────────────────────────────┘
N8 INJECTS coverage map before AI responds:{ skills: [
{ id: "sk-eng-001", state: "initiated", probe_count: 1 }, ← updated{ id: "communication", state: "not_yet", probe_count: 0 },
```
(^) ],{ id: "system-design", state: "not_yet", probe_count: 0 }
(^) }time_remaining_minutes: 43
[3s later] N7 COMPLETES:
{ skill_updates: [{ id: "sk-eng-001", new_state: "initiated", new_probe_count: 1,
(^) ], reason: "AI asked opening React question; candidate responded with React state challenge" }
(^) → N8 updates map: sk-eng-001 = initiated / probe_count 1discovered_skills: [] }
T=0:08 AI: "Hundreds of updates per second is significant. How were you
(^) → N6: Turn #3 saved (ai)managing that state — and what was breaking before you fixed it?"

### Exchange 2 — React deep probe (follow-up #1)

```
T=0:10 AHMAD: "We were using Redux with websocket events dispatching actions
directly. The problem was every update triggered a full re-renderof the dashboard. We profiled it and found 80% of renders were
unnecessary. Eventually we moved critical real-time data intolocal component state with useRef for things that don't need
to trigger renders, and used React.memo aggressively."
┌─────────────────────────────────────────────────┐│ N7 ASYNC — analyzing Turn #4 │
```

##### └─────────────────────────────────────────────────┘

```
N8 INJECTS before AI responds:
{ skills: [{ id: "sk-eng-001", state: "initiated", probe_count: 1 },
```
(^) ...← still initiated because N7 result not back yet (1 turn lag — acceptable)
(^) }]
[3s later] N7 COMPLETES:
{ skill_updates: [{ id: "sk-eng-001", new_state: "partial", new_probe_count: 2,
(^) testing strategy or broader architecture patterns" }reason: "probe_count >= 2; candidate showed solid React optimization but hasn't demonstrated
(^) → N8: sk-eng-001 = partial / probe_count 2] }
→ U5 (assessor live monitor) receives WebSocket push:
"React/Frontend Dev: initiated → partial"
T=0:14 AI: "useRef for non-render-triggering state is smart. When you profiled it — what tooling did you use, and how did you
decide where to draw the line between what stays in Reduxversus what moves to local state?"
→ N6: Turn #5 saved (ai)

### Exchange 3 — React: deeper probe + off-agenda discovery

```
T=0:17 AHMAD: "React DevTools Profiler and Chrome Performance tab. For the
line — we kept Redux for anything that needed to be sharedacross the app or persisted. Local state for ephemeral UI.
Separately, we also decomposed the app into micro-frontendsat some point because the team grew to 12 engineers and
deployments were becoming a bottleneck."
N7 DETECTS: "micro-frontends" mentioned — off-agenda skill!
[3s later] N7 COMPLETES:{ skill_updates: [
{ id: "sk-eng-001", new_state: "partial", new_probe_count: 3,reason: "Strong profiling and state partitioning reasoning — approaching covered but no
testing/architecture pattern signal yet" } ],
discovered_skills: [{ label: "Micro-frontend Architecture", first_mention: "Decomposed app into micro-frontends
with 12-engineer team" } ]
}→ N8: sk-eng-001 = partial / probe_count 3 ; discovered: Micro-frontend (initiated, probe_count 0)
```

```
N8 INJECTS coverage map (now includes discovered skill):
{ skills: [{ id: "sk-eng-001", state: "partial", probe_count: 3 },
```
(^) ],...
discovered: [{ label: "Micro-frontend Architecture", state: "initiated", probe_count: 0 }],priority_next: "discovered" ← system nudges: briefly probe discovery
}
T=0:22 AI: "Interesting — 12 engineers on one frontend is a real coordination problem. How did you split the micro-frontends, and what did
Module Federation or the equivalent look like for you?[Ahmad answers briefly — ~2 exchanges]
Right, good. What tends to break first at that kind of teamboundary? [Ahmad answers]
Okay. Let's come back to the dashboard — when you think aboutthe overall component architecture, how did you structure it
so new engineers could contribute without breaking things?"
→ N7 updates: Micro-frontend (initiated → partial, probe_count 2)→ Coverage injection guides AI back to sk-eng-001 (still partial)

### Exchange 4 — React: covered

```
T=0:30 [After 2 more exchanges on component architecture and testing strategy]
N7 COMPLETES:{ skill_updates: [
{ id: "sk-eng-001", new_state: "covered", new_probe_count: 5,reason: "Candidate demonstrated: state management tradeoffs, profiling methodology,
component architecture, test strategy (unit+integration+e2e). Sufficient for L3 assignment." } ]
}→ N8: sk-eng-001 = covered
→ U5 push: "React/Frontend Dev: partial → covered ✓"
Coverage map now shows:
sk-eng-001: covered communication: not_yet ✓
system-design: not_yetdiscovered: Micro-frontend (partial)
priority_next: "communication"
```
### Exchanges 5–8 — Communication (abbreviated)

```
T=0:32 AI naturally bridges: "The way you described convincing the team to move away from Redux — walk me through how that conversation
actually went. Who was in the room?"
```

```
[6 exchanges covering: how Ahmad framed the proposal, how he handled pushback,how he documented the decision for async teammates]
T=0:51 N7: communication → covered (probe_count 4)
→ U5 push: "Communication: not_yet → covered ✓"
```
### Exchanges 9–11 — System Design

```
T=0:53 AI bridges: "You've described some complex systems. If you were starting
the logistics dashboard from scratch today, with everythingyou know now — where would you start the design?"
[5 exchanges on: component hierarchy, data layer design, performance budget]
T=1:08 N7: system-design → covered (probe_count 3)
→ U5 push: "System Design: not_yet → covered ✓"
```
### Session End (T=38:00)

```
N8 detects: ALL configured skills = covered
Coverage map final state:sk-eng-001: covered (probe_count: 5)
communication: covered (probe_count: 4)system-design: covered (probe_count: 3)
discovered: Micro-frontend (partial, probe_count: 2)time_remaining: 7 minutes
N9 TRIGGERED: end_reason = "all_covered"
→ session status: ended
N8 INJECTS final message with time warning:{ "all_skills_covered": true, "wrap_up": true }
T=38:00 AI: "I think we've covered everything I wanted to explore today.
That was a solid conversation, Ahmad. Do you have any questionsabout the role or the engineering team?"
[30s Q&A, then Ahmad says he's good]
T=38:45 AI: "Great. Thanks for your time — you'll hear back shortly."
T=38:45 Ahmad clicks [End Interview] (or session ends naturally when AI finishes)
→ N9: session status = ended, ended_at = T=38:45, duration_seconds = 2325
```
## Phase 4 — Portfolio Generation (T=38:45 to T=41:00)


N9 triggers N10 (portfolio generator)
N10 CALL: Gemini Pro
Input:- Full transcript: 41 turns (N6)

- Final coverage map (N8)- Skill definitions from cfg-001 (N1)

Processing: ~2 minutes
N10 OUTPUT:
{ "configured_skills": [
{"skill_id": "sk-eng-001",
"skill_label": "React / Frontend Development","level": 3,
"confidence": "high","evidence": [

(^) need to trigger renders\"","\"We moved critical real-time data into local component state with useRef for things that don't
(^) 400KB\"","\"We introduced route-level code splitting which dropped our initial bundle from 2.1MB to
(^) fetching layer, and e2e on critical user paths\"""\"For the test strategy I layered unit tests on pure functions, integration tests on the data-
],"competency_summary": "Ahmad demonstrates solid L3 proficiency in frontend development. He handles
complex state management problems with clear tradeoff reasoning and owns performance optimization end-to-end including profiling and measurement. His testing strategy is mature for a mid-level engineer, covering
unit through e2e. The main gap between L3 and L4 is that he has not yet defined team-wide standards orbuilt reusable systems adopted by others — he applies good patterns but hasn't elevated them into team-
level infrastructure." },
{"skill_id": "communication",
"skill_label": "Communication","level": 2,
"confidence": "medium","evidence": [
(^) meeting\"","\"I put together a one-pager with the profiling data and shared it in Slack before the
(^) ],"\"I framed it as a performance risk rather than a technical preference\""
(^) how to frame proposals for non-technical stakeholders. However, the evidence suggests his async"competency_summary": "Ahmad communicates clearly in technical 1:1 contexts and shows awareness of
communication is functional rather than proactive — he documented the decision but when asked aboutkeeping distributed teammates informed, he described ad-hoc rather than systematic approaches. Sits at L (^)
with clear path to L3 through more structured communication habits." },
{"skill_id": "system-design",


```
"skill_label": "System Design",
"level": 3,"confidence": "high",
"evidence": ["\"I'd start with the data contracts — what does each component consume, and how often does it
change\"", "\"The performance budget has to be set before the architecture, not after, otherwise you optimize
the wrong thing\"", "\"For something this size I'd introduce a design token system so the visual layer is decoupled
from the logic layer\"" ],
```
(^) with data contracts and performance budgets before structural decisions, which is characteristic of"competency_summary": "Ahmad demonstrates L3 system design thinking for frontend systems. He leads
engineers who have been burned by late-stage optimization. His design reasoning accounts for teamonboarding and maintainability, not just technical correctness. Slightly above the L2 expectation for this (^)
role." }
],"discovered_skills": [
{"skill_label": "Micro-frontend Architecture",
"level": 2,"confidence": "low",
"evidence": ["\"We decomposed into micro-frontends using Module Federation — four apps sharing a design system
shell\"" ],
(^) exchanges, probe_count 2. Confidence is low; warrants a dedicated session if this skill is critical for"competency_summary": "Ahmad has hands-on micro-frontend experience. Only briefly explored — 2 (^)
the role. Current evidence supports L2 at minimum." }
(^) }]
→ N11: Portfolio stored (portfolio-001)
→ Assessor's results page becomes available

## Phase 5 — Review & Fit/Gap (T=41:00 onward)

```
[Dimas opens results page]
U7 renders configured skills portfolio: React/Frontend Dev → L3 HIGH confidence
Communication → L2 MEDIUM confidence ← below L3 expectedSystem Design → L3 HIGH confidence ← above L2 expected
Dimas reads Communication evidence, agrees AI rating looks right.
Dimas reads System Design — thinks the L3 call is strong, agrees.
Dimas clicks [Run Fit/Gap] → selects vacancy: "Senior Frontend Engineer (TechCorp)"
```

```
N13 runs: Rule-based comparison:
React/Frontend Dev: candidate L3 vs expected L3 → Communication: candidate L2 vs expected L3 → ✅⚠ GAP (-1 level) MATCH
System Design: candidate L3 vs expected L2 → ⭐ EXCEED (+1 level)
LLM narrative call:input: vacancy culture_dimensions ("ownership, directness, async-first culture")
```
(^) output: 2-paragraph culture narrative+ portfolio competency summaries
U10 renders fit/gap report:
┌─────────────────────────────────────────────┬──────────┬──────────┬──────────┐
│ Skill │ Required │ Ahmad │ Result │├─────────────────────────────────────────────┼──────────┼──────────┼──────────┤
│ React / Frontend Development │ L3 │ L3 │ │ Communication │ L3 │ L2 │ ✅⚠ Gap-1 │ Match │
│ System Design │ L2 │ L3 │ └─────────────────────────────────────────────┴──────────┴──────────┴──────────┘⭐ +1 │
Culture & Competency:
"Ahmad's technical depth and ownership mindset align strongly with TechCorp'sengineering culture. He frames problems commercially (performance risk vs.
technical preference) and shows systematic thinking. The communication gapat L2 vs required L3 is the primary area to probe in a hiring conversation —
specifically whether he can drive async communication proactively rather thanreactively. His system design capability exceeding the role requirement is a
positive signal for growth headroom."
Dimas exports PDF → N14 generates document → download served

## System State Timeline (Visual)

```
T=0:00 ──────────────────────────────────────────────────────────────────── Session opens. Coverage map: all not_yet.
T=0:02 ┌─ AI Turn 1: Opening question (React) ─────────────────────────────
T=0:05 │ Candidate Turn 1 ────────────────────────────────────────────────
│ ↓ async: N7 starts│ Coverage injected (not_yet → still not_yet, N7 not done yet)
T=0:08 │ AI Turn 2: First follow-up ──────────────────────────────────────
│ ← N7 done: React = initiated (probe_count: 1)
T=0:10 │ Candidate Turn 2 ──────────────────────────────────────────────── │ ↓ async: N7 starts
│ Coverage injected (initiated)
```

```
T=0:14 │ AI Turn 3: Deeper probe ───────────────────────────────────────── │ ← N7 done: React = partial (probe_count: 2) ← first state change!
│ → U5 PUSH: "React: initiated → partial"
~~~ [6 more exchanges on React] ~~~
T=0:30 │ ← N7 done: React = covered (probe_count: 5) │ → U5 PUSH: "React: partial → covered ✓"
└───────────────────────────────────────────────────────────────────
T=0:32 ┌─ Communication probing begins ───────────────────────────────────── ~~~ [6 exchanges] ~~~
T=0:51 │ ← Communication = covered └───────────────────────────────────────────────────────────────────
T=0:53 ┌─ System Design probing begins ──────────────────────────────────────
```
(^) T=1:08 │ ← System Design = covered~~~ [5 exchanges] ~~~
└───────────────────────────────────────────────────────────────────
T=38:00 ──────────────────────────────────────────────────────────────────── ALL SKILLS COVERED → N9 triggered → AI wraps up
T=38:45 Session ends
T=38:45 N10 starts (Gemini Pro) ─────────────────────────────────────────────
T=41:00 Portfolio generated → N11 stored ────────────────────────────────────────────────────────────────────
T=41:00 Assessor opens results page → reviews → runs fit/gap → exports

## WebSocket Reconnection Simulation (T=9:55)

```
T=9:55 Backend receives Gemini GoAway message:
{ "goAway": { "timeLeft": "5s" } }
Backend reads latest SessionResumptionUpdate token (received earlier):{ "sessionResumption": { "handle": "tok-gemini-resume-xyz", "resumable": true } }
Backend immediately opens NEW WebSocket to Gemini Live:
{"setup": {
...(same config)...,"session_resumption": { "handle": "tok-gemini-resume-xyz" }
```
(^) }}
T=9:58 New WebSocket connected. Session state restored.
Ahmad hears no interruption — the AI continues mid-conversation.


T=10:00 Old WebSocket closes (GoAway timeout reached — already replaced)
N6: Turn metadata updated to reflect WebSocket reconnect(optional: log reconnect event for diagnostics)
