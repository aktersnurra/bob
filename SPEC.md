# Bob v1

## Goal

Build **Bob**, a small stationary desktop robot with an expressive pan/tilt head, display eyes, camera, microphone array and speaker.

Bob should feel like a **small curious machine**, not a voice assistant in a plastic shell.

Personality direction:

* warm
* curious
* gently deadpan / dry humour
* child-friendly
* comfortable speaking Swedish and English
* expressive primarily through timing, gaze, head movement and eyes rather than excessive speech
* WALL·E-ish curiosity without imitation

Full/project name may be **Botty Bob**; everyday name is **Bob**.

The most important architectural principle is:

> Bob is not an LLM with sensors. Bob is a collection of perception, memory, attention, control, cognition and action systems. The LLM is one subsystem.

The architecture is loosely inspired by Chris Eliasmith's Semantic Pointer Architecture / Spaun: specialized systems communicate through compact structured representations rather than forwarding raw sensory information into one monolithic model.

Do not attempt to reproduce Spaun, spiking neurons or semantic pointers in v1.

---

# 1. Core principles

## 1.1 OCaml owns cognition and control

The main Bob process is written in OCaml.

OCaml owns:

* event types
* world state
* workspace / working memory
* attention
* conversation state
* identity state
* memory policy
* context projection
* LLM interaction
* action validation
* body-control policy
* orchestration
* latency tracing

ML implementations may live in local worker processes where appropriate.

Do not force PyTorch/OpenCV/Whisper into OCaml merely for purity.

## 1.2 Capability-oriented architecture

Every major subsystem must sit behind a small interface.

Conceptually:

```ocaml
module type Vision = sig ... end
module type Audio = sig ... end
module type Identity = sig ... end
module type STT = sig ... end
module type TTS = sig ... end
module type Memory = sig ... end
module type Brain = sig ... end
module type Body = sig ... end
module type Clock = sig ... end
```

Implementations must be swappable.

Prefer explicit module injection / higher-order construction over global singletons.

## 1.3 Do not pipe everything sequentially

Never build:

```text
camera
→ face recognition
→ audio
→ STT
→ memory
→ LLM
→ TTS
→ motors
```

Bob consists of concurrent loops communicating through typed events and state.

Use Eio fibers unless there is a compelling reason not to.

---

# 2. Hardware target

Host:

```text
2026 Intel NUC
Linux
prefer 32 GB RAM
```

Bob itself:

```text
camera
4-mic circular array
small OLED face
2-axis head
speaker
talk button
hardware microphone kill switch
visible listening indicator
```

NUC placement is not architecturally important. It may live in Bob's base or externally during development.

Do not delay software waiting for final enclosure CAD.

---

# 3. Hardware choices

## Audio

Use:

```text
reSpeaker Flex XVF3800 Circular-4
base/no-XIAO version
USB mode
```

Use the XVF3800 for:

```text
VAD
direction of arrival
beamforming
AEC
AGC
noise suppression
dereverberation
processed microphone audio
```

The circular array belongs near the top/head of Bob.

The processing board may live lower in the body using the supplied FPC.

Do not duplicate these DSP functions in the NUC unless benchmarking demonstrates a reason.

## Camera

Default:

```text
small UVC USB board camera
Arducam B0520 or equivalent
1080p30
~90–100° FOV
good low-light performance
```

Camera is mounted in Bob's head approximately aligned with his gaze direction.

The camera backend must depend only on UVC semantics so another camera can replace it later.

## Head

Two degrees of freedom:

```text
yaw
pitch
```

Default actuators:

```text
2 × ROBOTIS DYNAMIXEL XL330-M288-T
```

Use smooth velocity/acceleration profiles.

Avoid twitching.

Motion itself is part of Bob's personality.

## Body controller

Use:

```text
OpenRB-150
```

It controls:

```text
Dynamixel bus
OLED
buttons
simple LEDs
body-local state
```

The NUC communicates with OpenRB over USB serial using a tiny versioned protocol.

The NUC must issue semantic commands such as:

```text
look_angle
look_at_track
eyes_expression
eyes_blink
set_attention_indicator
```

Never expose PWM or raw servo manipulation to the LLM.

## Display

Start with:

```text
1.3" 128×64 monochrome SH1106 OLED
```

Use it primarily for eyes.

Animations should be minimal:

```text
neutral
blink
looking left/right/up/down
curious
thinking
sleeping
```

Do not turn the face into a UI dashboard.

## Audio output

Start with one enclosed:

```text
4 Ω
~5 W
mono speaker
```

Prefer using the reSpeaker audio path initially because AEC is valuable.

The TTS/output backend remains replaceable.

---

# 4. Hardware privacy

Wake word is NOT required for v1.

Provide:

```text
physical MIC OFF switch
momentary TALK button
physical listening indicator
```

MIC OFF must be a real hardware boundary.

Do not implement it as:

```text
software mute = true
```

The switch must electrically prevent capture by removing power from the microphone front-end / switched microphone power domain.

The listening indicator should be electrically coupled to that same powered state where practical, so software cannot present the microphone as physically off while it is powered.

For the first prototype it is acceptable if hard-muting the Flex also temporarily removes Bob's speaker output.

Do not let this detail delay the main prototype.

---

# 5. Perception architecture

Raw sensor data must remain inside perception subsystems wherever possible.

The OCaml cognitive core receives structured observations.

Example:

```ocaml
type 'a observation = {
  value : 'a;
  confidence : float;
  observed_at : Time.t;
  source : source;
}

and source =
  | Vision
  | Audio
  | Identity_model
  | Memory
  | Inference
```

Bob must preserve the distinction between:

```text
observed
inferred
remembered
```

Do not silently collapse them.

---

# 6. Vision pipeline

Vision worker owns the camera stream.

Target camera rate:

```text
30 fps
```

Do NOT run face recognition at camera rate.

Pipeline:

```text
camera
   ↓
face detector
   ↓
cheap tracker
   ↓
track IDs
   ↓
occasional identity recognition
```

## Detection

Start with SCRFD.

Target:

```text
~5–10 Hz detection
```

Obtain:

```text
face bounding box
5 facial landmarks
quality estimate
```

## Tracking

Tracking is a separate cheap system.

Start simple:

```text
Kalman motion state
IoU / geometric association
Hungarian assignment if needed
```

The expected scene is only a handful of people.

Do NOT add a deep person-ReID tracker unless actual failures justify it.

Track at camera rate.

## Face recognition

Default recognizer:

```text
CVLFace
AdaFace
ViT-Base
KP-RPE
WebFace4M
512-D embedding
```

Face recognition answers:

```text
"who is this track?"
```

It does NOT perform tracking.

Run recognition:

```text
on new track
when identity becomes uncertain
after long occlusion/reappearance
occasionally for validation
```

Normal steady-state recognition should be <= 1 Hz and usually far below that.

Once:

```text
track_7 = Gustaf
```

is established, continue using track continuity rather than repeatedly invoking the ViT.

Identity confidence must be explicit.

---

# 7. Person identity

A Person is not a face embedding.

The architecture should conceptually be:

```text
face evidence ─┐
               │
voice evidence ├── Person_id
               │
context ───────┘
```

Only face evidence is required for v1.

Future voice embeddings must be possible without changing the Person abstraction.

Use stable IDs:

```ocaml
type person_id
type track_id
```

Never use a person's display name as their database key.

---

# 8. Stranger enrollment

Admin/owner may be pre-enrolled.

For an unknown high-quality face interacting with Bob:

```text
unknown person
↓
conversation establishes that they are addressing Bob
↓
Bob asks their name naturally
↓
person says their name
↓
create stable Person_id
↓
capture several good face observations
↓
store embeddings + selected reference image
↓
create semantic person profile
```

Aim for roughly 5–10 varied initial samples rather than one photograph.

Capture useful variation:

```text
frontal
slight left/right
different expressions
natural lighting variation
```

Do not train the network.

Enrollment only creates an embedding gallery.

---

# 9. Face-gallery maintenance

Bob may improve a known person's gallery over time.

Only add an observation if:

```text
track continuity is strong
identity confidence is high
face quality is sufficient
there is no conflicting identity evidence
```

Avoid self-poisoning.

Keep a bounded gallery, e.g. approximately 32 embeddings/person.

Prefer diversity rather than simply storing the newest 32.

The user's children will change appearance over time, so gradual refresh is desirable.

---

# 10. Audio and speaker association

Audio perception produces at least:

```text
speech_started
speech_ended
DoA
processed audio stream
VAD state/confidence
```

The first job of DoA is NOT transcription.

Its first job is attention.

When speech begins:

```text
VAD
↓
DoA
↓
controller immediately orients Bob toward that direction
```

This happens before Whisper and before the LLM.

If visual tracks exist, estimate each track's azimuth relative to the camera/head.

Associate speaker approximately by:

```text
closest visual track to audio DoA
+ temporal continuity
+ confidence
```

If no matching visual track exists:

```text
orient toward DoA
↓
camera acquires person
↓
track them
↓
identify asynchronously
```

Do not implement neural active-speaker/lip-sync detection in v1.

Leave an extension point for it.

---

# 11. Speech recognition

Run STT locally.

Default:

```text
whisper.cpp
large-v3-turbo-q5_0
multilingual
```

Swedish and English must both work.

The STT interface must support:

```text
partial transcript events
final transcript
language estimate if available
timestamps
```

Do not wait until an utterance finishes before beginning transcription.

Pipeline:

```text
VAD starts
↓
stream audio to Whisper
↓
partial text while person speaks
↓
end-of-turn
↓
final transcript immediately available
```

Keep OpenRouter/audio STT as a replaceable alternative backend but not the default.

Benchmark Intel CPU/iGPU acceleration on the actual NUC rather than assuming a specific runtime.

---

# 12. Turn detection

VAD is necessary but not sufficient.

Implement a turn state machine roughly:

```text
Idle
Listening
Possible_end
Committed
```

Avoid aggressive cutoffs during natural pauses.

The exact silence threshold is configuration, not architecture.

Support interruption:

If Bob is speaking and strong user speech begins:

```text
stop/pause TTS
attention → speaker
begin new input turn
```

This is essential for natural interaction.

---

# 13. Cognitive architecture

Core flow:

```text
Sensors
   ↓
Perception
   ↓
World model
   ↓
Workspace
   ↓
Controller / attention
   ↓
Context projector
   ↓
LLM
   ↓
Proposed actions / speech
   ↓
Controller validation
   ↓
Body / TTS
```

The LLM is not Bob's world model.

The LLM is not Bob's motor controller.

The LLM is not responsible for detecting who spoke.

---

# 14. World model

The world model contains Bob's current beliefs about physical reality.

Examples:

```ocaml
type person_state = {
  track : track_id;
  identity : identity;
  bearing : angle observation;
  visible : bool;
  speaking : bool;
  last_seen : Time.t;
}
```

Possible world contents:

```text
visible people
known identities
unknown identities
speaker
positions/bearings
objects later
Bob's own head orientation
```

World state is continuously updated by events.

Sensor-derived facts expire when stale.

Example conceptual TTLs:

```text
track visibility         ~seconds
speaker assignment       ~seconds
position/bearing         ~seconds
DoA                      sub-second/seconds
```

TTL values must be configurable.

---

# 15. Workspace / working memory

The workspace is NOT the same as world state.

It represents what Bob is actively maintaining for cognition:

```text
current speaker
current addressee
attention target
conversation topic
active question
active goal
relevant entities
recent turns
```

Workspace state may persist even when its originating sensory observation has expired.

Example:

Gustaf says:

```text
"Where did I leave the screwdriver?"
```

The precise face coordinates may immediately become irrelevant.

But these remain active:

```text
speaker = Gustaf
topic = screwdriver
goal = answer Gustaf's question
```

This distinction is intentional and inspired by the separation between perceptual state and maintained cognitive state.

---

# 16. Attention and control

Control/routing is explicit and primarily deterministic.

Example policies:

```text
speech starts
→ attention := speech direction

known visible speaker acquired
→ attention := that person

unknown person addresses Bob
→ schedule identity recognition

known person begins meaningful conversation
→ preload compact person profile

utterance becomes final
→ retrieve relevant episodic memories
→ invoke brain

nobody is interacting
→ do not invoke brain
```

The controller should decide what needs cognition.

Do NOT continuously ask an LLM what Bob should pay attention to.

---

# 17. Latency classes

Treat latency as an architectural property.

## Reflex

Target:

```text
<100 ms to initiate response
```

Includes:

```text
VAD event
DoA update
interrupt current speech
begin head orientation
cheap tracking updates
```

The hard requirement is:

> Bob must begin visibly orienting toward a new speaker before STT or LLM inference completes.

## Perception

Target order:

```text
<500 ms
```

Includes:

```text
speaker ↔ visual track association
new face detection
partial STT
identity requests
```

## Cognition

Primary UX target:

```text
<1 second from end of user's utterance
to Bob beginning audible response
```

This is a target/SLO, not a guarantee.

Achieve it through concurrency:

while the user is speaking Bob should already be:

```text
transcribing
identifying speaker
maintaining workspace
loading compact profile
retrieving likely memories
```

## Background

No interactive deadline:

```text
memory consolidation
episode summarization
face-gallery maintenance
model updates
analytics
```

A slower class must never block a faster class.

---

# 18. Event model

Use an explicit event stream.

Example:

```ocaml
type event =
  | Person_entered of track_id
  | Person_left of track_id
  | Person_identified of track_id * person_id * confidence
  | Speech_started of audio_source
  | Speech_direction of angle * confidence
  | Speech_ended
  | Partial_utterance of string
  | Utterance of attributed_utterance
  | Attention_changed of focus
  | Brain_action of action
  | Body_event of body_event
```

Prefer:

```text
events
→ pure/replayable reducers
→ states
```

where practical.

Create deterministic event-trace tests.

---

# 19. Memory model

Bob has three principal memory timescales plus world state.

## A. Perceptual/world memory

Lifetime:

```text
milliseconds → seconds
```

Examples:

```text
face location
DoA
visibility
current mouth/speech state
track confidence
```

Expires automatically.

## B. Working/conversation memory

Lifetime:

```text
active conversation / active task
```

Includes:

```text
recent turns
topic
goal
speaker
attention
unresolved references
```

Do not expire this using one dumb fixed TTL while it is actively relevant.

Close a conversation episode after configurable inactivity and/or when all participants leave.

Start around:

```text
10 minutes inactivity
```

and tune empirically.

## C. Episodic memory

Persist complete interaction episodes.

Use SQLite.

Store:

```text
episode id
participants
timestamps
transcript
important world/context events
summary
links to semantic-memory updates
```

Provide FTS search.

Do not inject all episodes into prompts.

Retrieve them only when relevant.

## D. Semantic / long-term memory

Each known person has a small curated profile.

Conceptually:

```text
people/<person-id>/
    profile.md
    face/
        reference images
        embeddings
```

`profile.md` is NOT a transcript.

It contains durable knowledge such as:

```text
name
relationship
stable preferences
important ongoing projects
important recurring facts
interaction preferences
```

Keep it deliberately small.

Use a strict size budget.

Start around a few KB/person.

When full, consolidate rather than append forever.

---

# 20. Memory consolidation

At an episode boundary:

```text
completed episode
↓
background consolidation
↓
extract candidate durable facts
↓
compare against current semantic profile
↓
add/update/remove as appropriate
↓
write concise profile
```

Do not store every statement as long-term memory.

Examples:

```text
"My name is Olle."
→ durable

"Call me Olle, not Oliver."
→ durable

"I started working at Saab."
→ probably durable

"I'm tired today."
→ episodic only

"My cup is on the desk."
→ usually episodic only
```

Memory updates need provenance to the episode that caused them.

Long-term memory must be inspectable as normal files/text.

No vector database is required for v1.

SQLite FTS + compact Markdown profiles is the default.

Embeddings/search can be added later if actual retrieval quality requires them.

---

# 21. Context projector

This is a first-class module.

The brain NEVER receives the entire internal state.

Input:

```text
workspace
world state
active person's semantic profile
recent conversation
retrieved relevant episodes
```

Output:

```text
small human-readable/structured LLM context
```

Example:

```text
CURRENT
Gustaf is speaking to Bob.
Another unidentified person is visible nearby.
Bob is currently looking toward Gustaf.

RELEVANT PERSON MEMORY
Gustaf is Bob's admin.
...

RELEVANT PAST EVENT
...

RECENT CONVERSATION
...
```

Normally exclude:

```text
track_7
bounding-box coordinates
raw DoA values
512-D face embeddings
Kalman covariance
detector internals
camera frames
```

unless cognition explicitly requires them.

The goal is to turn perception into meaning before language reasoning.

---

# 22. Brain

Default remote cognition provider:

```text
OpenRouter
```

Model is configuration.

Do not bake a specific model name into domain logic.

Brain receives:

```text
Bob personality/system prompt
context projection
current utterance
allowed high-level capabilities
```

Brain produces a stream of:

```text
speech content
high-level proposed actions
```

Potential actions:

```ocaml
type action =
  | Say of text
  | Look_at of entity
  | Ask_name of track_id
  | Recall_more of query
  | Noop
```

Actions are proposals.

Controller validates and executes them.

The LLM never directly controls motors or arbitrary hardware.

---

# 23. TTS

TTS must stream.

Never:

```text
generate full LLM answer
↓
generate full WAV
↓
play WAV
```

Instead:

```text
LLM tokens
↓
sentence/chunk boundary
↓
TTS
↓
audio playback
```

Start with local Piper/OHF Piper because it is lightweight and Swedish is available.

Keep TTS completely replaceable because Bob's eventual voice/personality quality is important.

Voice should eventually feel:

```text
warm
slightly gravelly if possible
calm
gently deadpan
not cartoonishly childish
```

Voice-model experimentation must not block architecture.

---

# 24. Bob personality

Bob should not behave like ChatGPT in a robot.

Desired tendencies:

```text
short answers by default
curiosity
occasional dry humour
comfortable silence
recognizes people naturally
does not announce internal technical states
does not constantly ask follow-up questions
child-friendly
does not patronize children
```

Movement can communicate before speech.

Example:

```text
someone speaks
→ Bob turns to them

unknown person
→ slight curious head tilt

recognition resolves
→ eyes/head settle

thinking
→ subtle eye/head behavior
```

Avoid excessive animations.

---

# 25. Process boundaries

Recommended:

```text
bob-core           OCaml
vision-worker      Python/native ML
whisper-worker     whisper.cpp/native
body-controller    OpenRB firmware
```

Potentially collapse workers later.

## vision-worker

Own:

```text
UVC camera
SCRFD
landmarks
tracking
CVLFace
face-quality selection
```

Emit only structured events/observations over a local IPC channel.

Do not continuously send full frames to OCaml.

## whisper-worker

Own:

```text
streaming audio → Whisper
partials
final transcripts
```

## IPC

Start boring.

Use:

```text
Unix-domain sockets
versioned newline-delimited JSON
```

unless there is a demonstrated need for something more sophisticated.

Keep transport hidden behind OCaml interfaces so serialization can change later.

---

# 26. Body protocol

OpenRB firmware exposes semantic commands/events.

Example commands:

```text
look yaw pitch speed
neutral
expression curious
expression thinking
blink
sleep
wake
```

Example feedback:

```text
head_position
motor_current
motor_temperature
button_pressed
fault
```

The body controller owns low-level motion interpolation and hardware safety.

The NUC should not have to issue 100 Hz servo setpoints for normal gestures.

---

# 27. Simulation and development

Before physical integration, build an event replay harness.

Example trace:

```text
t=0.000 Speech_started doa=-31
t=0.040 Person_entered track=7 bearing=-29
t=0.220 Person_identified track=7 person=gustaf
t=0.400 Partial_utterance "Bob where..."
t=1.500 Utterance gustaf "Bob where did I put the screwdriver?"
```

Run the real:

```text
world reducer
workspace
controller
memory retrieval
context projector
brain
```

against fake perception.

This lets most Bob development happen without hardware attached.

---

# 28. Observability

Latency instrumentation is mandatory from day one.

Every event carries a monotonic timestamp.

Record spans for:

```text
speech detected
orientation command
motor movement start
first STT partial
STT final
memory retrieval complete
LLM request
LLM first token
TTS first sample
speaker first audio
```

Expose one command/report that answers:

```text
speech-start → movement-start
speech-end → STT-final
speech-end → LLM-first-token
speech-end → first-audio
```

Do not attempt latency optimization without measurements.

---

# 29. Persistence

Suggested layout:

```text
bob-data/
    bob.db

    people/
        <person-id>/
            profile.md
            face/
                refs/
                embeddings/

    episodes/
        optional exported human-readable files

    models/
        ...

    traces/
        ...
```

SQLite is canonical for episodic/session metadata.

Markdown is canonical for compact inspectable semantic profiles.

Binary arrays/files are fine for face embeddings.

---

# 30. Testing priorities

Unit/property test:

```text
world-state reducers
track lifecycle
stale observation expiry
speaker association
workspace maintenance
episode boundaries
identity transitions
memory consolidation invariants
action validation
```

Test dangerous/confusing states such as:

```text
unknown track cannot load arbitrary known person's memory
stale track cannot remain active speaker forever
low-confidence face match cannot silently become durable identity
LLM cannot directly actuate a motor
expired perceptual location cannot masquerade as current fact
```

Use fake Clock heavily.

---

# 31. Implementation phases

## Phase 0 — interfaces + simulator

Build:

```text
types
events
World
Workspace
Control
Memory interfaces
Brain interface
Body interface
trace replay
```

No real ML required.

## Phase 1 — Bob reacts

Integrate:

```text
reSpeaker
VAD
DoA
OpenRB
Dynamixel pan/tilt
```

Acceptance:

> Speak from one side and Bob begins turning toward the sound immediately.

No LLM is required to pass this phase.

## Phase 2 — Bob talks

Add:

```text
local Whisper
OpenRouter
streaming TTS
interruptions
```

Acceptance:

> Natural single-person spoken conversation with target <1 s end-of-turn → first Bob audio under normal conditions.

## Phase 3 — Bob sees people

Add:

```text
camera
SCRFD
tracker
speaker/track association
```

Acceptance:

> Bob maintains stable visual tracks and looks at the current speaker without invoking face recognition continuously.

## Phase 4 — Bob knows people

Add:

```text
CVLFace ViT-KPRPE
identity gallery
owner enrollment
stranger enrollment
```

Acceptance:

> Unknown visitor can introduce themselves and later be recognized.

## Phase 5 — Bob remembers

Add:

```text
episodes
SQLite FTS
per-person profile.md
consolidation
context projector
```

Acceptance:

> Bob recalls a useful prior interaction without carrying entire conversation history in every prompt.

## Phase 6 — make Bob feel alive

Tune:

```text
motion
eye timing
turn-taking
interruptions
speech pacing
speaker association
memory behavior
recognition thresholds
latency
```

Do not add major new capabilities until this phase feels good.

---

# 32. Explicit non-goals for v1

Do NOT implement:

```text
mobile base
arms
full-room SLAM
continuous VLM inference
camera-to-LLM streaming
neural active-speaker detection
voice-print recognition
semantic-pointer vectors
spiking neural networks
vector database
wake-word dependency
cloud STT as default
face recognition every frame
LLM-controlled servos
giant agent framework
distributed microservices
```

Keep extension points for the interesting ones.

---

# 33. Architecture invariant

Preserve this dependency direction:

```text
SENSORS
  ↓
PERCEPTION
  ↓
OBSERVATIONS
  ↓
WORLD
  ↓
WORKSPACE
  ↓
CONTROL
  ↓
CONTEXT PROJECTOR
  ↓
BRAIN
  ↓
PROPOSED ACTION
  ↓
CONTROL
  ↓
BODY
```

Memory interacts with Workspace/Context but does not bypass control.

The LLM must never become the owner of reality.

---

# 34. Definition of Bob v1

Bob v1 is done when:

1. Bob sits on a desk with expressive pan/tilt head and eyes.
2. Bob detects speech and immediately turns toward its direction.
3. Bob visually tracks the speaker.
4. Bob transcribes Swedish/English locally.
5. Bob identifies known faces asynchronously.
6. Bob can enroll an unknown person through natural conversation.
7. Bob attributes conversation turns to people.
8. Bob speaks through streaming TTS.
9. Bob can be interrupted naturally.
10. Bob maintains short-lived perceptual state separately from working memory.
11. Bob persists searchable episodes.
12. Bob maintains compact long-term profiles per person.
13. Bob consolidates long-term memories after interactions.
14. Bob sends only projected relevant context to the LLM.
15. Bob's LLM cannot directly manipulate hardware.
16. A physical switch can genuinely disable microphone capture.
17. Latency from speech-start to orientation and speech-end to response is measured.
18. All major ML/hardware subsystems are replaceable behind capabilities.

Most importantly:

> When someone starts talking, Bob should react before he has understood them.

That physical acknowledgement is more important to making Bob feel alive than adding another intelligence feature.
