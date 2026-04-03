# slices

## AI Mentoring Platform — Slices

#### Shape: B — Dual-Agent (Gemini Live Interviewer + Live Coverage Analyzer)

#### Date: 2026-02-

#### Shaping doc:

#### Breadboard:

#### shaping.md

#### breadboard.md

## Slicing Principle

#### Every slice ends in demo-able output. No horizontal layers (e.g., “just the data model” or “just the backend”). Each slice delivers

#### a vertical cut: UI + handler + data store, demo-able from end to end.

## V1: Config + Live Audio + Transcript {#v1}

#### Demo: Assessor creates an assessment config, sends a session invite. Candidate opens the link, clicks mic, has a real audio

#### conversation with the AI interviewer. Session ends manually. Full transcript is saved and viewable.

### Affordances

```
ID Affordance Type
U1 Assessment config
form (role, domains,
custom skill
definitions with L1-
L5 anchors, time
limit)
```
##### UI

```
U3 Candidate invite /
session link
generation
```
##### UI

```
U4 Candidate audio
interface (mic
button, timer,
connection status, AI
speaking indicator)
```
##### UI

```
U6 End interview button
(candidate side,
manual)
```
##### UI

```
N1 Assessment config
store
```
```
Data store
```
```
N2 System prompt
generator —
transforms config
into Gemini Live
system prompt with
probing instructions
```
```
Handler
```

### Wiring (V1)

```
Assessor fills U1 → saves N1 → triggers N2 (generate system prompt)
Assessor clicks U3 → creates N4 (session record) → generates shareable link
Candidate opens link → loads audio page
Candidate clicks mic → U4 → opens N5 (Gemini Live WebSocket)
N5 injects: system prompt + contextWindowCompression + sessionResumption
N5 streams audio in from U
N5 streams audio out → U4 (candidate hears AI)
N5 → N6 (each turn transcribed and stored)
Candidate clicks U6 → N9 (session marked ended)
```
### Session continuity detail (30-90 min)

```
N4 Session record store
(candidate_id,
config_id, status,
time_limit)
```
```
Data store
```
```
N5 Gemini Live session
manager — opens
WebSocket, injects
system prompt +
contextWindowComp
ression +
sessionResumption
; handles GoAway →
transparent
reconnect
```
```
Handler
```
```
N6 Transcript capture —
inputAudioTranscr
iption +
outputAudioTransc
ription → turn-by-
turn store with
speaker +
timestamp
```
```
Data store
```
```
N9 Session end handler
(manual trigger only
in V1) — marks
session ended
```
```
Handler
```
```
Event What happens
WebSocket
approaches 10-min
limit
```
```
Gemini sends
GoAway with
timeLeft
N5 catches GoAway Reads latest
SessionResumption
Update token
```

## V2: Live Coverage Loop {#v2}

#### Demo: During an active interview, the assessor opens the live monitor and watches skills move from not_yet → initiated →

#### partial → covered in real-time. The AI, informed by the coverage map, probes skills that are still thin and naturally exits skills

#### that are covered. Session auto-ends when all skills reach covered or the time ceiling hits.

### Affordances

### Coverage state machine

```
not_yet
```
```
N5 reconnects Opens new
WebSocket, passes
resumption token as
handle
Candidate
experience
```
```
No interruption —
gap is sub-second
```
```
ID Affordance Type
U5 Live coverage
monitor — assessor
view; shows each
skill and current
state; updates in
real-time via
WebSocket
```
##### UI

```
U6 End interview button
(assessor side,
added in V2)
```
##### UI

```
N7 Coverage analyzer
— async Gemini
Flash call after each
candidate turn;
extracts skill signals;
enforces hard rule
(no initiated →
partial move
without follow-up
confirmed); detects
off-agenda
discoveries
```
```
Handler
```
```
N8 Coverage map store
— { skill_id,
label, state,
probe_count,
last_signal } per
session; discovered
skills list; pushes
updates to U5 via
WebSocket
```
```
Data store
```

```
↓ (AI asks first question about this skill)
initiated
↓ (at least one follow-up probe confirmed by N7)
↓ (LLM judges signal sufficient for L1-L5 rating)
partial → covered
(LLM not yet (LLM confident
confident) enough to rate)
discovered → initiated → partial → covered
(off-agenda skill (same rules apply)
detected by N7)
```
### Wiring (V2, layered on V1)

```
N6 saves candidate turn → async trigger → N
N7: Gemini Flash call
input: last N turns of transcript + current coverage map
output: { skill_signal_updates[], discovered_skills[] }
N7 → N8 (update map states)
N8 → U5 (WebSocket push — assessor sees update)
N8 → N5 (inject coverage map as clientContent text before next AI turn)
N5 receives: [hidden system text] current coverage map JSON
AI reads map → probes partial/initiated skills → exits covered skills
→ briefly explores discovered skills → returns to agenda
Session end (auto):
N8 detects all skills = covered → N9 triggered
OR: time ceiling reached → N9 triggered
OR: U6 (assessor) → N9 triggered
```
## V3: Portfolio Generation {#v3}

#### Demo: After the session ends, the assessor opens the results page and sees a fully structured skill portfolio. Each configured

#### skill shows an L1-L5 badge, 2-3 evidence quotes from the transcript, and a competency summary paragraph. A separate

#### “Discovered Skills” section shows skills the AI probed outside the agenda.

### Affordances

```
ID Affordance Type
U7 Configured skills
portfolio view — skill
cards with L1-L
badge, evidence
quotes, competency
summary
```
##### UI


### Wiring (V3, layered on V1 + V2)

```
N9 (session ended) → triggers N
N10: Gemini Pro call
input: full transcript (N6) + final coverage map (N8) + skill definitions (N1)
output: per-skill portfolio JSON
configured skill: { skill_id, level L1-L5, evidence[2-3 quotes], competency_summary }
discovered skill: { label, level L1-L5, evidence[2-3 quotes], competency_summary }
N10 → N11 (persist portfolio)
Assessor opens results page:
N11 → U7 (configured skills rendered as cards)
N11 → U8 (discovered skills rendered below)
```
### Portfolio generator prompt strategy

```
U8 Discovered skills
section — same card
structure, separate
from configured
skills
```
##### UI

```
N10 Portfolio generator
— triggered by N
(session end);
Gemini Pro reads full
transcript + final
coverage map;
produces per-skill
portfolio; groups into
configured +
discovered
```
```
Handler
```
```
N11 Portfolio store — {
session_id,
candidate_id,
configured_skills[
],
discovered_skills[
], generated_at }
each skill has {
skill_id, level,
evidence[],
competency_summary
, ai_confidence }
```
```
Data store
```
```
Section Input used Output
Per configured skill Transcript turns
mentioning this skill
+ skill’s L1-L
anchors from config
```
```
Level assignment +
evidence selection +
competency
summary
```

## V4: Vacancy + Fit/Gap {#v4}

#### Demo: Assessor builds a job vacancy (expected React L3, Communication L3, System Design L2, culture notes). Runs the

#### fit/gap report against a candidate’s portfolio. Sees a skill-by-skill table (match / gap / exceed) plus a narrative paragraph on

#### culture and competency fit.

### Affordances

```
Per discovered skill Transcript turns
mentioning the
discovery + B
universal L1-L
anchors (as fallback)
```
```
Same structure
```
```
Confidence score Coverage map’s final
probe_count and
state for each skill
```
```
ai_confidence:
high / medium /
low
```
```
ID Affordance Type
U2 Vacancy builder
form — role name,
expected skills × L-
levels (from same
taxonomy), culture
dimensions (free
text), competency
expectations (free
text)
```
##### UI

```
U10 Fit/gap report view
— skill table
(candidate L vs
expected L per skill:
match / gap /
exceed) +
culture/competency
narrative section
```
##### UI

```
N3 Vacancy store — {
role,
expected_skills[],
culture_dimensions
,
competency_expecta
tions, tenant_id
}
```
```
Data store
```

### Fit/gap engine detail

```
Rule-based (per skill):
candidate.level > expected.level → exceed
candidate.level = expected.level → match
candidate.level < expected.level → gap (with delta: how many levels short)
skill not in portfolio → not assessed
LLM narrative (culture + competency):
input: vacancy.culture_dimensions + vacancy.competency_expectations
+ portfolio.configured_skills[].competency_summary
+ portfolio.discovered_skills[].competency_summary
output: 2-3 paragraph narrative (overall fit, standout strengths, notable gaps)
```
### Wiring (V4, independent of V2/V3 in setup; depends on N11 for report)

```
Assessor fills U2 → N3 (vacancy stored)
Assessor opens fit/gap report for a session:
N3 (vacancy expectations) + N11 (portfolio) + N12 (overrides if any) → N
N13 rule-based: produce skill comparison table
N13 LLM call: produce culture/competency narrative
N13 → fit/gap record (persisted)
fit/gap record → U10 (rendered as report)
```
## V5: Human Review + Export {#v5}

#### Demo: Assessor reviews a portfolio, reads the evidence, decides the AI rated “Communication” as L3 but the transcript

#### evidence actually shows L2. Adjusts to L2, adds a note. Fit/gap report automatically re-runs with the override. Clicks export —

#### downloads a PDF with the full portfolio, overrides noted, and the fit/gap report.

### Affordances

```
N13 Fit/gap engine —
rule-based: compare
candidate level vs
expected level per
skill; LLM narrative:
reads
culture_dimensions
+
competency_expect
ations against
portfolio
competency_summa
ries; merges into
fit/gap record
```
```
Handler
```
```
ID Affordance Type
```

### Wiring (V5, layered on V3 + V4)

```
Assessor reads U7/U8 (portfolio view)
Assessor clicks override on a skill → U
U9 → N12 (save override record)
N12 → triggers N13 re-run with overrides applied
N13 → U10 (fit/gap report updates)
Assessor clicks U11 (export):
N14 reads: N11 (portfolio) + N12 (overrides) + fit/gap record
N14 composes PDF:
Section 1: Interview metadata (candidate, role, date, duration)
Section 2: Configured skills (AI rating + override if changed + evidence + summary)
Section 3: Discovered skills (same structure)
Section 4: Fit/gap report (table + narrative)
Section 5: Assessor notes
N14 → download served to browser
```
## Slice Summary

```
U9 Override panel —
per-skill: shows AI
rating, evidence
quotes; assessor
can set override
level + add free-text
note; displays “AI: L
→ You: L2” diff
```
##### UI

```
U11 Export button —
generates PDF or
JSON download
```
##### UI

```
N12 Override store — {
session_id,
skill_id,
ai_level,
override_level,
assessor_notes,
overridden_by,
overridden_at }
```
```
Data store
```
```
N14 Export generator —
composes
PDF/JSON from N
(portfolio) + N
(overrides) + fit/gap
record; includes
both AI and human
ratings where
overridden
```
```
Handler
```
```
Slice Key affordances Demo-able outcome
```

##### V1 U1, U3, U4, U6, N1,

##### N2, N4, N5, N6, N

Live audio interview
with transcript
V2 U5, U6(assessor),
N7, N

Coverage map live-
updating; AI probes
smarter
V3 U7, U8, N10, N11 Structured skill
portfolio after
session
V4 U2, U10, N3, N13 Fit/gap report
against a vacancy
V5 U9, U11, N12, N14 Override ratings;
export full report
