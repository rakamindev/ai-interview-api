Here's the content from the provided PDFs converted into Markdown format.

---

# big-picture

## AI Interview Platform - Big Picture
Selected shape: B (Dual-Agent Gemini Live Interviewer + Live Coverage Analyzer)

### PRD Documents (Engineer Handoff)

| Doc | What it covers |
| :-- | :------------- |
| 01 — First Principles | AI behavior spec: system prompt template, probing rules, coverage injection format, coverage analyzer prompt, portfolio generator prompt, failure modes |
| 02 — Simulation | Complete end-to-end interview trace with timestamps, coverage state transitions, WebSocket reconnection, portfolio generation, and fit/gap output |
| 03 — UI Spec | ASCII mockups for all 8 screens, all states (empty, active, error), user flows |
| 04 — Technical Spec | Data models (SQL schemas), API endpoints, audio format, error handling, Rakamin integration notes, environment variables |

### Frame

**Problem**
*   Current skill assessments are static — fixed question lists that don't adapt to what the candidate actually says
*   An AI that just asks scripted questions misses nuance: shallow answers pass, strong answers aren't probed deeper
*   There is no structured way to produce a per-candidate skill portfolio (skills x L1-L5 levels) from a conversation
*   Matching candidates to vacancies is manual and subjective — no shared language between candidate capability and job requirements
*   Job vacancies describe expectations in prose; candidate skills exist in resumes — neither maps cleanly to the other

**Outcome**
*   Assessors configure **what** to assess (domains, hard/soft skills); the AI decides **how** to assess (crafts its own questions)
*   The AI interviews candidates dynamically — probing, following up, asking for clarity — like a skilled human interviewer
*   Each interview produces a structured skill portfolio: skill list with L1-L5 rating, behavioral evidence, competency summary
*   Job vacancies define expected skill levels and cultural/competency requirements in the same structured format
*   The platform can compare a candidate's portfolio against a vacancy's expectations and surface fit/gap analysis

### Shape

**Fit Check (R × B)**

| Req | Requirement | Status | B |
| :-- | :---------- | :----- | :- |
| R0 | AI conducts dynamic interviews — probing, following up, digesting answers, asking for clarity — like a skilled human interviewer, not a script reader | Core goal | ✅ |
| R1 | Assessor configures what to assess (domains + custom skill definitions); AI independently crafts and sequences its own questions from that agenda | Must-have | ✅ |
| R2 | Interview produces a structured skill portfolio: each assessed skill mapped to L1-L5 with behavioral evidence and competency summary | Must-have | ✅ |
| R3 | Job vacancies capture expected skill levels, company culture, and competency expectations in structured format matching the same skill taxonomy | Must-have | ✅ |
| R4 | Platform generates automated fit/gap analysis (candidate portfolio vs. vacancy); human assessor can review and override individual ratings | Must-have | ✅ |
| R5 | Platform is web-based and integrates with existing Rakamin HR tech ecosystem (multi-tenant, existing auth, API-ready) | Must-have | ✅ |
| R6 | Interview is audio-only and synchronous — real-time voice conversation, 30-90 minutes, continuous from candidate's perspective across any connection resets | Must-have | ✅ |
| R7 | AI probing adapts dynamically to candidate's actual responses — not a fixed question list or branching tree | Must-have | ✅ |
| R8 | Skill portfolio is human-readable and exportable (PDF or structured data) | Leaning yes | ✅ |

### Parts

| Part | Mechanism | Flag |
| :--- | :-------- | :--- |
| B1 | **Assessment config** — assessor defines domains + custom skills (name, scope, L1-L5 anchors) → system generates AI agenda (topic areas + probing intent, NOT question scripts) | |
| B2 | **Gemini Live session** — audio-only, real-time, system prompt encodes probing behavior and assessment agenda; AI crafts its own questions; accepts coverage map text injections alongside audio | |
| B3 | **Session continuity** — contextWindowCompression (sliding window) + sessionResumption tokens; backend catches GoAway and transparently reconnects; candidate hears no gap; supports 30-90 min | |
| B4 | **Transcript capture** — Gemini native inputAudioTranscription + outputAudioTranscription → stored turn-by-turn with speaker, timestamp, session\_id | |
| B5 | **Live coverage analyzer** — runs async (Gemini Flash) after each candidate turn; extracts skill signals; updates coverage map states (not\_yet → initiated → partial → covered); hard rule: skill stays initiated until follow-up probe confirmed; detects off-agenda discoveries → adds as initiated | |
| B6 | **Coverage steering injection** — every turn, before AI responds, current coverage map injected as hidden clientContent text into Gemini Live; AI uses map to probe partial/initiated skills deeper, exit covered skills, briefly probe discovered skills | |
| B7 | **Portfolio generator** — post-session; Gemini Pro reads full transcript + final coverage map; produces per-skill: L1-L5 rating, 2-3 evidence quotes, competency summary; groups into configured skills + discovered skills sections | |
| B8 | **Skill portfolio store** — structured record per session: configured\_skills[], discovered\_skills[], each with skill\_id, level, evidence[], competency\_summary, ai\_confidence | |
| B9 | **Human review UI** — assessor views AI-generated L-levels, reads evidence, adjusts level, adds notes; changes tracked (AI rating vs. human override) | |
| B10 | **Vacancy record** — structured form: role, expected skills × L-levels, culture dimensions, competency expectations; same taxonomy as assessment config | |
| B11 | **Fit/gap engine** — rule-based: candidate L vs. expected L per skill (match / gap / exceed); LLM narrative for culture/competency dimensions; merges AI portfolio + human overrides | |
| B12 | **Web UI** — candidate: audio session page (mic, timer, status); assessor: config wizard, live monitor, results dashboard, override interface, export | |

### Breadboard

```mermaid
flowchart TB
subgraph assessorConfig["PLACE: Assessor - Config & Vacancy"]
U1["U1: Assessment config form\n(skills, anchors, time limit)"]
U2["U2: Vacancy builder form\n(expected skills × levels, culture)"]
U3["U3: Candidate invite / session link"]
N1["N1: Config store"]
N2["N2: System prompt generator"]
N3["N3: Vacancy store"]
N4["N4: Session record store"]
end
subgraph candidateSession["PLACE: Candidate - Interview Page"]
U4["U4: Audio interface\n(mic, timer, status)"]
U6a["U6: End interview button"]
end
subgraph assessorMonitor["PLACE: Assessor - Live Monitor"]
U5["U5: Coverage map monitor\n(read-only, live)"]
U6b["U6: End interview button"]
end
subgraph backend["PLACE: Backend - Session Engine"]
N5["N5: Gemini Live session manager\n(WebSocket, compression, resumption)"]
N6["N6: Transcript capture\n(turn-by-turn, timestamped)"]
N7["N7: Coverage analyzer\nasync, Gemini Flash"]
N8["N8: Coverage map store\n(live, per-session)"]
N9["N9: Session end handler"]
N10["N10: Portfolio generator\nGemini Pro, post-session"]
N11["N11: Portfolio store"]
N12["N12: Override store"]
N13["N13: Fit/gap engine"]
N14["N14: Export generator"]
end
subgraph assessorResults["PLACE: Assessor - Results Page"]
U7["U7: Configured skills portfolio view"]
U8["U8: Discovered skills section"]
U9["U9: Override panel"]
U10["U10: Fit/gap report view"]
U11["U11: Export button"]
end
U1 --> N1
U1 --> N2
U2 --> N3
U3 --> N4
N2 --> N5
U4 --> audio stream| N5
N5 --> audio out | U4
N5 --> N6
N6 --> new candidate turn N7
N7 --> update map | N8
N8 -.->|inject before each AI turn| N5
N8 -.->push via WebSocket | U5
U6a -->|end signal | N9
U6b -->|end signal | N9
N9 --> N10
N10 --> N11
N11 -.-> U7
N11 -.-> U8
U9 --> N12
N12 --> N13
N3 -.-> vacancy expectations | N13
N13 -.-> U10
U11 --> N14
N14 -.->|PDF/JSON| U11
classDef ui fill:#ffb6c1, stroke:#d87093,color:#000
classDef nonui fill:#d3d3d3, stroke:#808080,color:#000
class U1,U2,U3,U4,U5,U6a,U6b,U7,U8,U9,U10,U11 ui
class N1,N2,N3,N4,N5,N6,N7,N8,N9,N10,N11,N12,N13,N14 nonui
```

**Legend:**
*   **Pink nodes (U)** = UI affordances (things users see/interact with)
*   **Grey nodes (N)** = Code affordances (data stores, handlers, services)
*   **Solid lines** = Wires Out (calls, triggers, writes)
*   **Dashed lines** = Returns To (return values, reads, pushes)

### Slices

### Sliced Breadboard

```mermaid
flowchart TB
subgraph slice1["V1: CONFIG + LIVE AUDIO + TRANSCRIPT"]
U1["U1: Config form"]
U3["U3: Session invite"]
U4["U4: Audio interface"]
U6a["U6: End button (candidate)"]
N1["N1: Config store"]
N2["N2: System prompt generator"]
N4["N4: Session record store"]
N5["N5: Gemini Live session manager"]
N6["N6: Transcript capture"]
N9a["N9: Session end handler\n(manual only)"]
end
subgraph slice2["V2: LIVE COVERAGE LOOP"]
U5["U5: Coverage monitor (assessor)"]
U6b["U6: End button (assessor)"]
N7["N7: Coverage analyzer\n(async, Gemini Flash)"]
N8["N8: Coverage map store"]
N9b["N9: Auto end\n(all covered / time ceiling)"]
end
subgraph slice3["V3: PORTFOLIO GENERATION"]
U7["U7: Configured skills view"]
U8["U8: Discovered skills section"]
N10["N10: Portfolio generator\n(Gemini Pro)"]
N11["N11: Portfolio store"]
end
subgraph slice4["V4: VACANCY + FIT/GAP"]
U2["U2: Vacancy builder"]
U10["U10: Fit/gap report view"]
N3["N3: Vacancy store"]
N13["N13: Fit/gap engine"]
end
subgraph slice5["V5: HUMAN REVIEW + EXPORT"]
U9["U9: Override panel"]
U11["U11: Export button"]
N12["N12: Override store"]
N14["N14: Export generator"]
end
%% Force slice ordering
slice1 ~~~ slice2
slice2 ~~~ slice3
slice3 ~~~ slice4
slice4 ~~~ slice5

%% Cross-slice wiring
N1 --> N2 --> N5
U4 -->|audio| N5 -->|audio | U4
N5 --> N6
U6a --> N9a
N6 --> candidate turn| N7
N7 --> N8
N8 -.->|inject | N5
N8 -.->|WebSocket | U5
U6b --> N9b
N9a --> N10
N9b --> N10
N10 --> N11
N11 -.-> U7
N11 -.-> U8
U2 --> N3
N3 -.-> N13
N11 -.-> N13
N13 -.-> U10
U9 --> N12 --> N13
U11 --> N14

%% Slice colors
style slice1 fill:#e8f5e9, stroke:#4caf50, stroke-width:2px
style slice2 fill:#e3f2fd, stroke:#2196f3, stroke-width:2px
style slice3 fill:#fff3e0, stroke:#ff9800,stroke-width:2px
style slice4 fill:#f3e5f5, stroke:#9c27b0,stroke-width:2px
style slice5 fill:#fff8e1, stroke:#ffc107, stroke-width:2px

classDef ui fill:#ffb6c1, stroke:#d87093,color:#000
classDef nonui fill:#d3d3d3, stroke:#808080,color:#000
class U1,U2,U3,U4,U5,U6a,U6b,U7,U8,U9,U10,U11 ui
class N1,N2,N3,N4,N5,N6,N7,N8,N9a,N9b,N10,N11,N12,N13,N14 nonui
```

### Slices Grid
*(This section was visually represented as an empty grid in the original PDF, so it's captured as a heading here)*

| V1: CONFIG + LIVE AUDIO 🎙️ | V2: LIVE COVERAGE LOOP 🔬 | V3: PORTFOLIO GENERATION 📈 |
| :------------------------- | :----------------------- | :------------------------ |
| PENDING • Assessment config form + store • System prompt generator • Gemini Live session (compression + resumption) • Transcript capture (turn-by-turn) • Manual session end <br> Demo: Candidate has real audio interview; transcript saved | PENDING • Async coverage analyzer (Gemini Flash) • Coverage map store + WebSocket push • Coverage injection into Gemini Live (every turn) • Live coverage monitor for assessor • Auto session end (all covered / time ceiling) <br> Demo: Assessor watches skills move not\_yet → covered in real-time; AI probes smarter | PENDING • Post-session portfolio generator (Gemini Pro) • Portfolio store (configured + discovered skills) • Configured skills view (L1-L5, evidence, summary) • Discovered skills section <br> Demo: After session ends, assessor sees full skill portfolio with ratings and evidence |
| V4: VACANCY + FIT/GAP 🎯 | V5: HUMAN REVIEW + EXPORT 📝 | |
| PENDING • Vacancy builder form + store • Fit/gap engine (rule-based L-levels + LLM narrative) • Fit/gap report view (match / gap / exceed) <br> Demo: Assessor builds vacancy, runs against portfolio, sees skill-by-skill fit report | PENDING • Override panel (adjust L-level, add notes) • Override store (tracks AI rating vs. human rating) • Fit/gap re-runs with overrides applied • Export generator (PDF + JSON) <br> Demo: Assessor overrides a rating, fit/gap updates, exports full report | |

---
