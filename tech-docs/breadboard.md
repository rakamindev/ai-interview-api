# breadboard

## AI Mentoring Platform — Breadboard (Shape B)

#### Date: 2026-02-

#### Shape: B — Dual-Agent (Gemini Live Interviewer + Live Coverage Analyzer)

## UI Affordances

```
ID Affordance Place Wires Out
```
```
U1 Assessment config
form (role, domains,
custom skill
definitions with L1-
L5 anchors, time
limit)
```
```
Assessor: Config
Page
```
```
→ N1 (save config),
→ N2 (generate
system prompt)
```
```
U3 Candidate invite /
session link
```
```
Assessor: Config
Page
```
```
→ N4 (create
session record)
```
```
U4 Candidate audio
interface (mic
button, timer,
connection status, AI
speaking indicator)
```
```
Candidate: Interview
Page
```
```
→ N5 (audio stream
to Gemini Live)
```
```
U5 Live session monitor
(assessor can
observe status —
coverage map state,
time remaining;
read-only)
```
```
Assessor: Live
Monitor
```
```
← N8 (coverage map
updates via
WebSocket)
```
```
U6 “End interview”
button (assessor or
candidate can
terminate early)
```
```
Candidate: Interview
Page / Assessor:
Live Monitor
```
```
→ N9 (trigger
session end)
```
```
U7 Portfolio view —
configured skills
section (skill name,
L1-L5 badge,
evidence quotes,
competency
summary)
```
```
Assessor: Results
Page
```
```
← N11 (portfolio
record)
```
```
U8 Discovered skills
section (skills AI
probed that were
not configured —
same structure as
U7)
```
```
Assessor: Results
Page
```
```
← N11 (portfolio
record)
```
```
U9 Override panel —
assessor can adjust
AI-assigned L-level
per skill, add notes
```
```
Assessor: Results
Page
```
```
→ N12 (save
override)
```

## Non-UI Affordances

```
U10 Fit/gap report view
(skill-by-skill
comparison vs
vacancy: match /
gap / exceed +
culture narrative)
```
```
Assessor: Results
Page
```
```
← N13 (fit/gap
record)
```
```
U11 Export button (PDF
or JSON of full
portfolio + fit/gap
report)
```
```
Assessor: Results
Page
```
```
→ N14 (generate
export)
```
```
ID Affordance Type Wires Out
```
```
N1 Assessment config
store — persists
config per session
(skills, anchors, time
limit, tenant_id)
```
```
Data store
```
```
N2 System prompt
generator —
transforms config
(skill names,
anchors, probing
intent) into Gemini
Live system prompt;
includes instructions
for follow + note on
off-agenda
discoveries
```
```
Handler → N5 (system
prompt injected at
session start)
```
```
N3 Vacancy store —
persists vacancy
record (role,
expected skills × L-
levels, culture
dimensions) per
tenant
```
```
Data store
```
```
N4 Session record store
— candidate_id,
config_id, start_time,
status (pending /
active / ended),
time_limit
```
```
Data store
```

N5 Gemini Live session
manager — opens
WebSocket to
Gemini Live API;
injects system
prompt +
contextWindowComp
ression +
sessionResumption
configs; streams
audio in/out; handles
GoAway →
transparent
reconnect with
resumption token

```
Handler → N6 (audio
transcription), → N
(coverage injection
per turn)
```
N6 Transcript capture —
Gemini
inputAudioTranscr
iption +
outputAudioTransc
ription → stored
turn-by-turn with
speaker (AI /
candidate),
timestamp,
session_id

```
Data store → N7 (each new
candidate turn
triggers async
coverage analysis)
```
N7 Coverage analyzer
(async) — on each
new candidate turn:
Gemini Flash call
reads last N turns +
coverage map;
extracts skill signals;
applies hard rule
(skill stays
initiated until
follow-up probe
confirmed); updates
map states
(not_yet →
initiated →
partial →
covered); detects
off-agenda skills →
adds as initiated

```
Handler → N8 (write updated
coverage map)
```
N8 Coverage map store
— live record per
session: `{ skill_id,
label, state: not_yet

```
initiated partial
```
N9 Session end handler
— triggered by: (a)
AI wraps up when all
skills covered, (b)
time ceiling reached,
© U6 manual end;
marks session as
ended; triggers N

```
Handler → N10 (portfolio
generation)
```

## Wiring Diagram

```
N10 Portfolio generator
— reads full
transcript (N6) +
final coverage map
(N8); sends to
analysis LLM
(Gemini Pro);
produces per-skill:
L1-L5 rating, 2-
evidence quotes,
competency
summary paragraph;
groups into
configured skills +
discovered skills
```
```
Handler → N11 (write
portfolio record)
```
```
N11 Portfolio store —
structured record:
session_id,
candidate_id,
configured_skills[],
discovered_skills[],
generated_at; each
skill has: skill_id,
level, evidence[],
competency_summa
ry, ai_confidence
```
```
Data store
```
```
N12 Override store —
assessor
adjustments:
session_id, skill_id,
original_ai_level,
override_level,
assessor_notes,
overridden_at
```
```
Data store → N13 (re-run
fit/gap with
overrides applied)
```
```
N13 Fit/gap engine —
rule-based:
candidate level vs.
expected level per
skill (match / gap /
exceed); LLM
narrative call for
culture/competency
dimensions; merges
AI portfolio + any
human overrides
```
```
Handler → fit/gap record
(persisted alongside
portfolio)
```
```
N14 Export generator —
composes PDF or
JSON from N11 +
N13; includes
configured skills,
discovered skills,
fit/gap report,
assessor notes
```
```
Handler
```

flowchart TB

subgraph assessorConfig["PLACE: Assessor — Config & Vacancy"]

U1["U1: Assessment config form<br/>(skills, anchors, time limit)"]

U2["U2: Vacancy builder form<br/>(expected skills × levels, culture)"]

U3["U3: Candidate invite / session link"]

N1["N1: Config store"]

N2["N2: System prompt generator"]

N3["N3: Vacancy store"]

N4["N4: Session record store"]

end

subgraph candidateSession["PLACE: Candidate — Interview Page"]

U4["U4: Audio interface<br/>(mic, timer, status)"]

U6a["U6: End interview button"]

end

subgraph assessorMonitor["PLACE: Assessor — Live Monitor"]

U5["U5: Coverage map monitor<br/>(read-only, live)"]

U6b["U6: End interview button"]

end

subgraph backend["PLACE: Backend — Session Engine"]

N5["N5: Gemini Live session manager<br/>(WebSocket, compression, resumption)"]

N6["N6: Transcript capture<br/>(turn-by-turn, timestamped)"]

N7["N7: Coverage analyzer<br/>(async, Gemini Flash)"]

N8["N8: Coverage map store<br/>(live, per-session)"]

N9["N9: Session end handler"]

N10["N10: Portfolio generator<br/>(Gemini Pro, post-session)"]

N11["N11: Portfolio store"]

N12["N12: Override store"]

N13["N13: Fit/gap engine"]

N14["N14: Export generator"]

end

subgraph assessorResults["PLACE: Assessor — Results Page"]

U7["U7: Configured skills portfolio view"]

U8["U8: Discovered skills section"]

U9["U9: Override panel"]

U10["U10: Fit/gap report view"]

U11["U11: Export button"]

end

%% Config setup

U1 --> N

U1 --> N

U2 --> N

U3 --> N

N2 --> N

%% Live session flow

U4 -->|audio stream| N


```
N5 -->|audio out| U
N5 --> N
```
```
%% Async coverage loop (runs after each candidate turn)
N6 -->|new candidate turn| N
N7 -->|update map| N
N8 -.->|inject before each AI turn| N
N8 -.->|push via WebSocket| U
```
```
%% Session end
U6a -->|end signal| N
U6b -->|end signal| N
N9 --> N
N10 --> N
```
```
%% Results
N11 -.-> U
N11 -.-> U
U9 --> N
N12 --> N
N3 -.->|vacancy expectations| N
N13 -.-> U
U11 --> N
N14 -.->|PDF/JSON| U
```
```
%% Node styles
classDef ui fill:#ffb6c1,stroke:#d87093,color:#
classDef nonui fill:#d3d3d3,stroke:#808080,color:#
```
```
class U1,U2,U3,U4,U5,U6a,U6b,U7,U8,U9,U10,U11 ui
class N1,N2,N3,N4,N5,N6,N7,N8,N9,N10,N11,N12,N13,N14 nonui
```
#### Legend:

#### Pink nodes (U) = UI affordances (things users see/interact with)

#### Grey nodes (N) = Code affordances (data stores, handlers, services)

#### Solid lines = Wires Out (calls, triggers, writes)

#### Dashed lines = Returns To (return values, reads, pushes)

## Key Flows Summary

### Setup flow (assessor)

#### U1 → N1 + N2 → N5 (system prompt ready) + U2 → N3 + U3 → N

### Live interview flow (per turn)

```
Candidate speaks → U4 → N5 (Gemini Live) → audio response → U
↓
N6 (transcript turn saved)
↓ async
```
#### •

#### •

#### •

#### •


```
N7 (Gemini Flash: extract signals, update states)
↓
N8 (coverage map updated)
↓ (next AI turn)
N5 ← N8 (map injected as hidden text before AI responds)
↓ WebSocket
U5 (assessor sees live coverage status)
```
### Session end flow

```
N9 triggered → N10 (Gemini Pro reads full transcript + final map) → N11 (portfolio stored)
```
### Review & match flow (assessor)

#### N11 → U7 + U8 (portfolio view) + U9 → N12 → N13 (fit/gap with overrides) + U11 → N14 (export)
