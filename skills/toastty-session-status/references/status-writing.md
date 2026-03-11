# Toastty Status Writing Guide

## Goal

Status updates should help the user answer three questions quickly:

1. What is the agent doing now?
2. Is it blocked?
3. Is there a useful result ready for me?

The sidebar is a compact summary surface, not a transcript. Optimize for clarity and signal.

## Cadence

Send a status update when one of these becomes true:

- meaningful work has started and the user would benefit from knowing the current phase
- the agent has moved into a new phase such as investigation, implementation, or validation
- the agent is blocked on a user decision or approval
- the current status would now be misleading because the work changed direction
- the agent has reached a useful handoff point and is waiting on the user

Avoid updates when:

- only a single shell command finished
- the agent is still in the same phase and nothing user-meaningful changed
- the new status text would just restate the old status with different wording
- the task is so short that intermediate telemetry adds more noise than value

For longer stretches of uninterrupted work, refresh `working` when the previous summary no longer describes the current work, or after several substeps where the status has gone stale. This keeps the user confident the run is still alive.

## Length

The UI renders both `summary` and `detail` on a single line.

- `summary`: aim for 2 to 5 words, roughly 24 characters or less
- `detail`: aim for a single short clause, roughly 72 characters or less

Prefer compact noun or verb phrases over full narrative sentences. Summaries are lowercase phrases; details are capitalized clauses. Neither uses trailing punctuation.

Repeating the same status is allowed, but it refreshes recency in the workspace. Use repeated `working` updates as deliberate liveness signals, not as background chatter. Avoid re-emitting `ready`, `needs_approval`, or `error` unless the user-meaningful state changed or the session left that state and later re-entered it.

Good summaries:

- `inspecting repo`
- `editing skill docs`
- `running tests`
- `awaiting approval`
- `ready for review`

Weak summaries:

- `working`
- `thinking`
- `doing the task the user asked for`
- `running command after command`

Good details:

- `Comparing CLI behavior with sidebar rendering`
- `Need approval to run the migration`
- `Skill docs drafted and tests passed`

Weak details:

- `I am now looking around the repository to see what might be going on`
- `Working hard on the thing`
- `ran rg, sed, and xcodebuild`

## State Selection

| Kind | Use when | Avoid when | Example summary | Example detail |
|------|----------|------------|-----------------|----------------|
| `working` | The agent is actively making progress. | The agent is blocked or already at a handoff point. | `editing skill docs` | `Writing the skill contract and examples` |
| `needs_approval` | The next step requires a user answer, approval, or access decision. | The agent can continue with a reasonable assumption. | `awaiting approval` | `Need approval to run the migration` |
| `ready` | The agent has a useful result, draft, or checkpoint and is waiting on the user. | The task has failed or the agent is still in the middle of active work. | `ready for review` | `Skill docs drafted and verified` |
| `error` | Progress stopped because of a failure the agent cannot route around. | The agent just needs clarification or approval. | `build failed` | `xcodebuild failed after Ghostty link step` |

## `needs_approval` vs `error`

Use `needs_approval` when the user can unblock the run by making a choice, such as approving a migration, supplying a missing product decision, or allowing a risky command.

Use `error` when the run hit a real failure, such as missing CLI integration, invalid routing context, or a build failure with no clear next repair step yet.

## `ready` vs `stop`

Use `ready` when the session is live and waiting on the user. Emit it when the agent reaches a handoff point, not as a periodic reminder while the same handoff is still pending. Use `session stop` only when the process or wrapper is actually exiting.

## State Transitions

Any status kind can transition to any other. There is no required ordering — if the agent recovers from an `error`, it can send `working` directly. If a `ready` result needs more work, send `working` again. If the agent is already `ready` and still waiting on the same review or response, do not emit another `ready` just to refresh recency. Send `ready` again only after work resumed and a new handoff point was reached. Just send the status that reflects the current reality.
