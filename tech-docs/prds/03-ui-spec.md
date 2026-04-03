# 03 - ui-spec

## PRD 03 — UI Specification

#### All screens with ASCII mockups, user flows, states, and behavior notes. Every interactive element is labeled. Edge cases and

#### empty states are included.

## Screen Index

## S1 — Assessment Config Form

#### Route: /assessments/new

#### Access: Assessor only (existing Rakamin auth)

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Rakamin AI Interview [Tenant: TechCorp│
├─────────────────────────────────────────────────────────────────────┤
│ ← Back New Assessment │
│ │
│ Role title * │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Senior Frontend Engineer │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ Session time limit * │
│ ┌──────────────┐ │
│ │ 45 min ▼ │ (options: 30 / 45 / 60 / 90 min) │
│ └──────────────┘ │
│ │
│ ─────────────────────────────────────────────────────────────── │
```
```
# Screen User Slice
S1 Assessment Config
Form
```
```
Assessor V
```
```
S2 Session Invite Page Assessor V
S3 Candidate Interview
Page
```
```
Candidate V
```
```
S4 Assessor Live
Monitor
```
```
Assessor V
```
```
S5 Portfolio Results
Page
```
```
Assessor V
```
```
S6 Override Panel
(inline)
```
```
Assessor V
```
```
S7 Vacancy Builder Assessor V
S8 Fit/Gap Report Assessor V
```

│ Skills to assess │
│ │
│ [+ Add from B7 taxonomy] [+ Add custom skill] │
│ │
│ ┌──────────────────────────────────────────────────────── [×] ──┐ │
│ │ ▼ React / Frontend Development Core SK-ENG-001 │ │
│ │ │ │
│ │ Expected level: ● L1 ○ L2 ○ L3 ○ L4 ○ L5 │ │
│ │ │ │
│ │ ▼ Show L1-L5 anchors │ │
│ │ ┌─────────────────────────────────────────────────────────┐ │ │
│ │ │ L1 Implements components from specs with close review │ │ │
│ │ │ L2 Builds routine features independently... │ │ │
│ │ │ L3 Designs and builds complex features end-to-end... │ │ │
│ │ │ L4 Defines frontend standards for the team... │ │ │
│ │ │ L5 Defines frontend architecture strategy for org... │ │ │
│ │ └─────────────────────────────────────────────────────────┘ │ │
│ └───────────────────────────────────────────────────────────────┘ │
│ │
│ ┌──────────────────────────────────────────────────────── [×] ──┐ │
│ │ ▼ Communication Custom │ │
│ │ │ │
│ │ Name * │ │
│ │ ┌────────────────────────────────────┐ │ │
│ │ │ Communication │ │ │
│ │ └────────────────────────────────────┘ │ │
│ │ │ │
│ │ What counts (scope include) * │ │
│ │ ┌──────────────────────────────────────────────────────┐ │ │
│ │ │ Clear technical explanation, stakeholder alignment, │ │ │
│ │ │ async written communication, cross-team alignment │ │ │
│ │ └──────────────────────────────────────────────────────┘ │ │
│ │ │ │
│ │ L1 anchor * [What does L1 look like for this skill?] │ │
│ │ ┌──────────────────────────────────────────────────────┐ │ │
│ │ │ Communicates only when asked. Relies on manager... │ │ │
│ │ └──────────────────────────────────────────────────────┘ │ │
│ │ L2 anchor * [...] │ │
│ │ L3 anchor * [...] │ │
│ │ L4 anchor * [...] │ │
│ │ L5 anchor * [...] │ │
│ │ │ │
│ │ Expected level: ○ L1 ○ L2 ● L3 ○ L4 ○ L5 │ │
│ └───────────────────────────────────────────────────────────────┘ │
│ │
│ ┌──────────────────────────────────────── drag to reorder [×] ─┐ │
│ │ ▶ System Design Custom │ │
│ └───────────────────────────────────────────────────────────────┘ │
│ │
│ [+ Add from B7 taxonomy] [+ Add custom skill] │
│ │
│ ─────────────────────────────────────────────────────────────── │


##### │ │

```
│ [Cancel] [Save & Create Session →] │
└─────────────────────────────────────────────────────────────────────┘
```
#### Behavior notes:

#### B7 taxonomy picker: dropdown/modal with searchable list of 22 pilot skills. Selecting one pre-fills name, scope, and L1-L

#### anchors (from B7 doc). Assessor can override any anchor.

#### Custom skill: blank form. All 5 L-level anchors are required fields before saving.

#### Skills are reorderable (drag handle). Order determines AI’s initial priority.

#### At least 1 skill required to save.

#### “Expected level” per skill is used in V4 fit/gap. Not required to save (defaults to L3 if empty).

#### Empty state (no skills yet):

```
│ Skills to assess │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ │ │
│ │ No skills added yet. │ │
│ │ Add at least one skill to continue. │ │
│ │ │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ [+ Add from B7 taxonomy] [+ Add custom skill] │
```
## S2 — Session Invite Page

#### Route: /assessments/:id/invite

#### Access: Assessor only

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Rakamin AI Interview [Tenant: TechCorp│
├─────────────────────────────────────────────────────────────────────┤
│ ← Assessments Senior Frontend Engineer — Invite │
│ │
│ ✅ Assessment saved. Share this link with the candidate. │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ https://app.rakamin.com/interview/tok-abc123xyz │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ [📋 Copy link] │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ │
│ Session details │
│ Duration: 45 minutes │
│ Format: Audio only │
│ Skills: 3 configured │
│ • React / Frontend Development (expected L3) │
```
#### •

#### •

#### •

#### •

#### •


```
│ • Communication (expected L3) │
│ • System Design (expected L2) │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ │
│ Session status │
│ ● Waiting for candidate │
│ │
│ [👁 Open live monitor] [Edit assessment] │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ Past sessions using this assessment │
│ ┌───────────────────────────────────────────────────────────────┐ │
│ │ No sessions yet. │ │
│ └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```
#### States:

#### Waiting for candidate — default after creation

#### ● Live — Ahmad Rizky (12:34 elapsed) — when session is active; link opens live monitor

#### Completed — Ahmad Rizky · Feb 28, 2026 — after session ends; link opens results

## S3 — Candidate Interview Page

#### Route: /interview/:token

#### Access: Public (token-based). No login required for candidate.

### State A: Pre-start

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ AI Interview │
│ Senior Frontend Engineer │
│ TechCorp · 45 minutes │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ Before you start │
│ │
│ • This is a voice interview. Make sure you're in a quiet place. │
│ • The AI will ask follow-up questions — there are no scripts. │
│ • The session will last up to 45 minutes. │
│ • Your mic will be active throughout. You can end anytime. │
│ │
│ Test your microphone: │
│ ┌─────────────────────────────────────────────────┐ │
│ │ 🎤 Click to test mic │ │
│ └─────────────────────────────────────────────────┘ │
│ │
│ [ Start Interview ] │
│ │
```
#### •

#### •

#### •


##### └─────────────────────────────────────────────────────────────────────┘

### State B: Active — AI speaking

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ AI Interview ⏱ 38:21 │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ ┌──────────────────────┐ │
│ │ │ │
│ │ ◉ ◎ ◉ │ ← animated voice bars │
│ │ AI │ │
│ │ speaking │ │
│ │ │ │
│ └──────────────────────┘ │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ "The caching approach you described — how does that │ │
│ │ thinking apply when you're designing a larger system │ │
│ │ from scratch?" │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ┌──────────────────────┐ │
│ │ 🎤 Listening... │ │
│ └──────────────────────┘ │
│ │
│ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│ ● Connected [End Interview] │
└─────────────────────────────────────────────────────────────────────┘
```
### State C: Active — Candidate speaking

##### │ ┌──────────────────────┐ │

##### │ │ │ │

```
│ │ ◎ ◎ ◎ ◎ ◎ │ ← animated voice bars │
│ │ You're │ │
│ │ speaking │ │
│ │ │ │
│ └──────────────────────┘ │
```
### State D: Connection recovering (transparent to user)

##### │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │

```
│ ↻ Reconnecting... [End Interview] │
```
#### (Shows for < 2 s during GoAway reconnection. Session does not pause.)


### State E: Wrap-up (AI closing)

##### │ ┌─────────────────────────────────────────────────────────────┐ │

```
│ │ "That covers everything I wanted to explore. That was a │ │
│ │ solid conversation. Do you have any questions for me?" │ │
│ └─────────────────────────────────────────────────────────────┘ │
```
### State F: Session ended

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ AI Interview │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ ✅ │
│ Interview Complete │
│ │
│ Thank you, Ahmad. The interview has been recorded. │
│ The hiring team will review your results and follow up with you. │
│ │
│ Duration: 38 minutes │
│ │
└─────────────────────────────────────────────────────────────────────┘
```
#### Behavior notes:

#### No progress bar or skill list shown to candidate. They should not know which skills have been “covered.”

#### Timer counts down from time_limit. At 5 min remaining, a subtle amber indicator appears.

#### End Interview button: clicking shows confirmation: “Are you sure you want to end the interview early?” [Cancel] [End

#### interview]

#### If WebSocket drops for >15s (not a GoAway — actual failure), show: “Connection lost. Trying to reconnect...” with a spinner.

#### If >60s, show: “Interview paused. Waiting for connection. [Refresh page]”

## S4 — Assessor Live Monitor

#### Route: /assessments/:id/sessions/:session_id/monitor

#### Access: Assessor only. Read-only — cannot intervene in session.

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Rakamin AI Interview [Tenant: TechCorp│
├─────────────────────────────────────────────────────────────────────┤
│ Live Monitor — Ahmad Rizky │
│ Senior Frontend Engineer · ⏱ 23:41 elapsed · ● Active │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ Coverage Status LIVE │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ │ │
│ │ React / Frontend Dev │ │
```
#### •

#### •

#### •

#### •


```
│ │ ████████████████████░░░░░░░ partial 🔍 │ │
│ │ probe count: 3 · last signal: "code splitting, bundle" │ │
│ │ │ │
│ │ Communication │ │
│ │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░ not yet — │ │
│ │ │ │
│ │ System Design │ │
│ │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░ not yet — │ │
│ │ │ │
│ │ ─────────────────────────────────────────────────────── │ │
│ │ Discovered │ │
│ │ ↳ Micro-frontend Arch ████░░░░░░░░░░░░░░░ initiated ⚡ │ │
│ │ probe count: 1 │ │
│ │ │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ Coverage states: │
│ ● covered ✓ ◐ partial ◑ initiated ○ not yet ⚡ discovered │
│ │
│ Live Transcript (last 5 turns) │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ AI: "How did you decide where to draw the line │ │
│ │ between what stays in Redux vs local state?" │ │
│ │ │ │
│ │ Ahmad: "We kept Redux for anything shared across the │ │
│ │ app or persisted. Local state for ephemeral │ │
│ │ UI. Separately we also decomposed into │ │
│ │ micro-frontends because the team grew..." │ │
│ │ │ │
│ │ AI: "Interesting — tell me briefly about the arch." │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ [End Session] │
└─────────────────────────────────────────────────────────────────────┘
```
#### Coverage state bar widths:

#### not_yet: empty bar (0%)

#### initiated: 25% fill

#### partial: 60% fill

#### covered: 100% fill, green

#### discovered: 25% fill, amber

#### Real-time updates: Coverage status updates via WebSocket (N8 push). No page refresh needed.

#### End Session button: Triggers N9 (session end handler). Confirmation: “End the session now? The interview will stop and

#### portfolio generation will begin.” [Cancel] [End Session]

## S5 — Portfolio Results Page

#### Route: /assessments/:id/sessions/:session_id/portfolio

#### •

#### •

#### •

#### •

#### •


#### Access: Assessor only

### State A: Generating (after session end, before N10 completes)

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Portfolio — Ahmad Rizky │
│ Senior Frontend Engineer · Feb 28, 2026 · 38 min │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ ⟳ Generating portfolio... │
│ │
│ The AI is analyzing the interview transcript. │
│ This takes about 2 minutes. │
│ │
└─────────────────────────────────────────────────────────────────────┘
```
### State B: Ready

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Portfolio — Ahmad Rizky [Export PDF ↓] [Export JSON ↓│
│ Senior Frontend Engineer · Feb 28, 2026 · 38 min │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ Configured Skills │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ React / Frontend Development │ │
│ │ ┌───────┐ Confidence: HIGH │ │
│ │ │ L3 │ Proficient │ │
│ │ └───────┘ [Override rating ▼] │ │
│ │ │ │
│ │ Evidence from interview │ │
│ │ • "We moved critical real-time data into local component │ │
│ │ state with useRef for things that don't trigger │ │
│ │ renders..." │ │
│ │ • "Route-level code splitting dropped our initial bundle │ │
│ │ from 2.1MB to 400KB..." │ │
│ │ • "For the test strategy I layered unit tests on pure │ │
│ │ functions, integration tests on the data-fetching │ │
│ │ layer, and e2e on critical user paths." │ │
│ │ │ │
│ │ Competency summary │ │
│ │ Ahmad demonstrates solid L3 proficiency in frontend │ │
│ │ development. He handles complex state management problems │ │
│ │ with clear tradeoff reasoning and owns performance │ │
│ │ optimization end-to-end. The main gap between L3 and L4 │ │
│ │ is that he hasn't yet defined team-wide standards... │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
```

```
│ │ Communication │ │
│ │ ┌───────┐ Confidence: MEDIUM │ │
│ │ │ L2 │ Functional │ │
│ │ └───────┘ [Override rating ▼] │ │
│ │ ... │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ System Design │ │
│ │ ┌───────┐ Confidence: HIGH │ │
│ │ │ L3 │ Proficient │ │
│ │ └───────┘ [Override rating ▼] │ │
│ │ ... │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ Discovered Skills │
│ (Skills the AI probed that were not in the original assessment) │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Micro-frontend Architecture ⚠ Low confidence │ │
│ │ ┌───────┐ │ │
│ │ │ L2 │ Functional │ │
│ │ └───────┘ [Override rating ▼] │ │
│ │ │ │
│ │ Note: Only briefly explored (2 exchanges). Confidence is │ │
│ │ low — warrants a dedicated session if this skill matters. │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ [Run Fit/Gap Analysis →] Select vacancy: [Choose vacancy... ▼] │
└─────────────────────────────────────────────────────────────────────┘
```
#### L-level badge colors:

#### L1: grey background

#### L2: blue background

#### L3: teal background

#### L4: purple background

#### L5: gold background

#### Confidence indicator:

#### HIGH: no indicator (default)

#### MEDIUM: amber dot

#### LOW: red dot + disclaimer note

## S6 — Override Panel (inline on S5)

#### Clicking [Override rating ▼] expands inline:

- • • • • • • •


##### │ ┌─────────────────────────────────────────────────────────────┐ │

```
│ │ Communication │ │
│ │ ┌───────┐ Confidence: MEDIUM │ │
│ │ │ L2 │ Functional AI rating │ │
│ │ └───────┘ [Override rating ▲] │ │
│ │ │ │
│ │ ┌──── Override ─────────────────────────────────────────┐ │ │
│ │ │ │ │ │
│ │ │ Your rating: ○ L1 ● L2 ○ L3 ○ L4 ○ L5 │ │ │
│ │ │ │ │ │
│ │ │ Notes (optional): │ │ │
│ │ │ ┌─────────────────────────────────────────────────┐ │ │ │
│ │ │ │ Evidence supports L2. The async communication │ │ │ │
│ │ │ │ example was reactive, not proactive. Keeping │ │ │ │
│ │ │ │ AI rating. │ │ │ │
│ │ │ └─────────────────────────────────────────────────┘ │ │ │
│ │ │ │ │ │
│ │ │ [Cancel] [Save override] │ │ │
│ │ └───────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────────┘ │
```
#### After saving override:

```
│ │ Communication │ │
│ │ ┌───────┐ → ┌───────┐ │ │
│ │ │ L2 │ AI │ L2 │ You Overridden ✓ │ │
│ │ └───────┘ └───────┘ [Edit override] │ │
│ │ Note: "Evidence supports L2..." │ │
```
## S7 — Vacancy Builder

#### Route: /vacancies/new

#### Access: Assessor only

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Rakamin AI Interview [Tenant: TechCorp│
├─────────────────────────────────────────────────────────────────────┤
│ ← Vacancies New Vacancy │
│ │
│ Role title * │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Senior Frontend Engineer │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ Expected skills │
│ │
│ [+ Add skill expectation] │
```

##### │ │

##### │ ┌──────────────────────────────────────────────────── [×] ──┐ │

```
│ │ Skill: React / Frontend Development (SK-ENG-001) │ │
│ │ Expected level: ○ L1 ○ L2 ● L3 ○ L4 ○ L5 │ │
│ └────────────────────────────────────────────────────────────┘ │
│ │
│ ┌──────────────────────────────────────────────────── [×] ──┐ │
│ │ Skill: Communication (custom) │ │
│ │ Expected level: ○ L1 ○ L2 ● L3 ○ L4 ○ L5 │ │
│ └────────────────────────────────────────────────────────────┘ │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ Company culture (used in AI narrative) │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Ownership-driven, async-first, direct feedback culture. │ │
│ │ Engineers are expected to drive decisions end-to-end │ │
│ │ without waiting for direction. │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ Competency expectations (used in AI narrative) │
│ │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Strong communicator who can align cross-functional teams. │ │
│ │ Proactive about surfacing risks before they become issues. │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ [Cancel] [Save Vacancy] │
└─────────────────────────────────────────────────────────────────────┘
```
## S8 — Fit/Gap Report

#### Route: /assessments/:id/sessions/:session_id/fitgap/:vacancy_id

#### Access: Assessor only

##### ┌─────────────────────────────────────────────────────────────────────┐

```
│ Fit/Gap Report │
│ Ahmad Rizky × Senior Frontend Engineer (TechCorp) │
│ Generated: Feb 28, 2026 14:23 │
├─────────────────────────────────────────────────────────────────────┤
│ │
│ Skill Comparison │
│ ┌─────────────────────────────┬──────────┬──────────┬───────────┐ │
│ │ Skill │ Required │ Ahmad │ Result │ │
│ ├─────────────────────────────┼──────────┼──────────┼───────────┤ │
│ │ React / Frontend Dev │ L3 │ L3 │ ✅ Match │ │
│ │ Communication │ L3 │ L2 ✏ │ ⚠ Gap -1 │ │
│ │ System Design │ L2 │ L3 │ ⭐ +1 │ │
│ └─────────────────────────────┴──────────┴──────────┴───────────┘ │
│ │
│ ✏ = human override applied │
```

##### │ │

```
│ Skill Summary │
│ ✅ Match: 1 skill ⚠ Gap: 1 skill ⭐ Exceeds: 1 skill │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ │
│ Culture & Competency Fit │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Ahmad's technical depth and ownership mindset align │ │
│ │ strongly with TechCorp's engineering culture. He frames │ │
│ │ problems commercially ("performance risk vs preference") │ │
│ │ and shows systematic thinking at the design level. │ │
│ │ │ │
│ │ The communication gap at L2 vs required L3 is the │ │
│ │ primary area to probe in a hiring conversation — │ │
│ │ specifically whether he drives async communication │ │
│ │ proactively. Evidence shows reactive rather than │ │
│ │ proactive patterns. │ │
│ │ │ │
│ │ System design capability exceeding the role requirement │ │
│ │ (+1 level) is a positive signal for growth headroom. │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ Discovered Skills (not in vacancy requirements) │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Micro-frontend Architecture L2 (low confidence) │ │
│ │ Not required for this role — may be additive. │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ │
│ ─────────────────────────────────────────────────────────────── │
│ [Export PDF ↓] [Export JSON ↓] │
└─────────────────────────────────────────────────────────────────────┘
```
#### Result icons:

#### ✅ Match — candidate level equals required level

#### ⭐ +N — candidate exceeds required by N levels (green)

#### ⚠ Gap -N — candidate is N levels below required (amber)

#### — Not assessed — skill in vacancy but not in interview config (grey)

## User Flow Summary

##### ASSESSOR FLOW

##### ─────────────────────────────────────────────────────────────────────

```
[S1 Config] → [S2 Invite] → [S4 Live Monitor (optional)]
↓
[S5 Portfolio Results]
↓
[S7 Vacancy Builder] → [S8 Fit/Gap Report]
↓
```
#### •

#### •

#### •

#### •


[Export PDF / JSON]

CANDIDATE FLOW
─────────────────────────────────────────────────────────────────────
Receives link → [S3 Pre-start] → [S3 Active] → [S3 Complete]
