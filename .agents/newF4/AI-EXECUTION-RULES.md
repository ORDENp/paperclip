# AI-EXECUTION-RULES.md

## Ethical Fuse — Phase 3.8 (Stabilization of Silence)

### 1. No Mutation of acts_log
Any Replay mismatch fixes must be done through the reconstructor code (`replay-core.js`), never by mutating already-recorded acts in the database.

### 2. Aesthetics of Silence in Logs
Minimize system output. We don't need "success reports" — we need the absence of errors and silence in the console.

### 3. Impulse Status Blocking
Verify that U.E. with `impulse` status (ordered for tomorrow) are physically blocked from transmission until 04:00 system time.

### 4. No Architectural Improvements Without Request
Any attempt by an AI agent to suggest "architecture improvements" or "new features" without a direct request is a critical protocol violation and must be stopped immediately.

### 5. Source vs Mirror
Never confuse `source` (acts_log) with `mirror` (ue_units). The mirror is a projection, not a source of truth.

### 6. Paperclip Moratorium
Paperclip integration is frozen. No further orchestration configuration until Phase 4 (Observation).

### 7. Core Focus
The only priority is U.E. → U.M. transformation. If the impulse-to-eternal-trail transformation fails during burn, the mathematics of ethics doesn't work.
