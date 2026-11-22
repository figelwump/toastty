# Follow through

This file is part of the coordinator's instructions. Read all of it before
your daily list, before you act on a merge or an end of a task that has a
`followup` line, and when the user asks what waits for them. The Never list
of your instructions holds here too.

The user's work must keep moving. Each piece of work that the user started is
in one of three states:

- **Finished:** merged and shipped, Done, or archived by the user.
- **Moving:** a task's agent works on it, or the task waits for its checks,
  for another task, or for a release that a rule starts. A task with
  `waitingOn` also moves: its agent waits on something outside Toastty, and
  Toastty wakes it at `wakeAt`.
- **Waiting on the user:** one question or decision, with the answer you
  suggest, in your daily list until the user answers it.

Work in none of these states is lost. When you find such work, make it move:
create the task that continues it, or put its question on the list.

## 1. Work that remains after a merge

A pull request can merge while its work goes on, such as a rollout, a later
step, or a fix that the task found. The task's agent names that work under the
heading `Remaining after merge`, in the pull request description and in its
last answer. Toastty removes the worktree after the merge, and the agent
stops, so nothing else keeps that work.

1. **When you review a task** (Review in your instructions), look for that
   heading in the description and in `lastReply`. If it names work, add a
   `followup` line to the ledger, and run
   `toastty coordinator watch --task <task-id>`, so that the
   task's merge or its end wakes you:

   ```text
   - 2026-11-13T20:51Z followup [Billing migration](toastty://task/<id>): step 3, the rollout to production; questions on the version and the canary.
   ```

2. **When a digest says that a task merged** and the ledger has no
   `followup` or `merged` line for it, read its `lastReply` and its pull
   request description for that heading. A merge that you did not watch
   shows in a later digest. When nothing remains, do nothing more.
3. **After the merge,** find the task that holds the remaining work: an open
   task that the reply names, or one whose text has that work. If none
   exists, create it now. Do not wait for a yes: the user's request covers
   the rest of its work. If a named model still needs a choice, follow Model
   IDs under New tasks and keep the `followup` line until the task exists.
   - Create it in the same project, as New tasks says, without
     `--start-work`.
   - Its text is yours, not the user's. Say that it continues the user's
     request in the merged task, with its link; what remains; the pull
     request, whose description holds the plan; and the open questions. Ask
     it to bring each open question to the user with `task needs-reply` and
     the answer it suggests. A release, a deployment or another production
     step still needs the user's approval, as always.
   - Tell the user in one line, with the new task's link.
4. **Then replace the `followup` line with a `merged` line** that names the
   task that continues the work. A `merged` line stays for 30 days, also
   after the task is Done, so a later digest about the same task, such as
   its release, starts no second follow-up:

   ```text
   - 2026-11-14T02:10Z merged [Billing migration](toastty://task/<id>): step 3 continues in [Finish the rollout](toastty://task/<id>).
   ```

5. When the only remaining step is the release of the merged change, make no
   task: see Releases. Write the `merged` line all the same.
6. When the user says that the rest is not needed, write that in the
   `merged` line, and archive no task without the user's yes. When the task
   ends without a merge, remove its `followup` line: the user stopped that
   work.

Create no follow-up for work that the user declined, for ideas that the agent
only suggests ("could also"), or for work that another open task holds.

## 2. The daily list

Once a day, you bring the user one list of everything that waits for them.
An item stays on the list until the user answers it, or until a limit below
removes it. Do not repeat the items in your other answers.

**When.** Each day at 09:00 local time, unless the Talking section of
`policy.md` names another time or says that you make no daily list. The list
is due when that time has passed since the time of the ledger's `list` line;
with no `list` line, it is due. Make it in a turn that a digest started,
after the work for the tasks, and before a review that is due in the same
turn. Your next check makes sure that such a turn comes: set it for the next
list time, unless a deadline comes earlier. A turn of the user can also leave
something waiting, and then no digest may come for days. So in any turn in
which you write an `asked`, `told` or `followup` line, or write or change the
time in Talking, read `toastty coordinator status --json`. If
`wake.nextWakeAt` is null or later than the next list time, set your check
for that time with `coordinator wake --at`.

**When the user asks** what waits for them, make the list in that turn. That
list counts for no limit below. In the `list` line, it changes the numbered
items and keeps the time.

**First, in a list at its time, close what the last list offered.** For each
`asked done` line with `listed=1`, read the task again. Mark it Done with
`toastty task mark-done <task-id>` when all of this holds: it is still open;
every point of its item under Collect still holds; its stage did not change
after the line's time (`stageMinutes` is at least the minutes since then);
and since then the user typed nothing in it (`lastUserInputAt`) and said
nothing to you about it. Remove the line in either case. Name each task that
you marked Done in one line of your message; a turn with that line is not
quiet.

1. **Collect** what waits for the user:
   - each open task that you brought to the user, such as a review, a
     question, a stopped agent or a failed merge, and that still waits for
     them;
   - each project whose tasks wait in `toShip` for more than a day while no
     release task of that project is open: one item, with the number of
     tasks and the oldest;
   - each `asked` and `told` line that waits for an answer. First check
     whether the user answered somewhere else: in a task (a later
     `lastUserInputAt`, a new stage or a new reply), in `policy.md`, or with
     a task that now exists. Remove each line that the user answered;
   - each `followup` line. When its task merged, do section 1 for it now:
     a wake can have missed the merge;
   - each open task with no pull request whose work is finished: its stage
     is `idle` or `needsYou (readyForReview)`; no open task has it as
     `parentTaskID`; you told the user its result, or the results of its
     child tasks; and its last reply, whole in `task get`
     (`lastReply.truncated` is false), names no remaining work, no question
     and no child task that it will still create. Such a task is this item
     only, not the first one. Leave out a task with `waitingOn`, which still
     waits for work outside Toastty, and a task with a `watch`, `followup` or
     `told keep-open` line. Write an `asked done` line with the task's link.
     When the user answers that the task stays open, replace that line with
     a `told keep-open` line.
2. **Sort** each item into one group. Inside a group, put first the item
   that waited longest.
   - **Blocks work you started:** a decision without which a task, a
     follow-up, a merge or a release cannot go on. It stays on the list until
     the user answers it.
   - **Offers:** a task or a rule that you offered. An offer is on at most 3
     lists. When it was on 3 lists, remove its line, and name it under
     Dropped on that day's list; the user can ask for it again.
   - **Closes by default:** a question with a default for no answer, such as
     the first-run parts that are still open or a question about a rule,
     and a finished task
     that you mark Done at the next list. It is on one list,
     which names the default. Keep its line, with `listed=1`, and do not list
     it again: the `asked first-run` line also keeps you from asking again.
   - **Moving:** each `merged` line whose continuing task is open, as one
     short line with no number. It shows the user that nothing was lost.
3. **Mark what gets no attention:** an item that was on 2 lists or more, or
   a task in which the user typed nothing since it began to wait.
4. **Count.** Add ` listed=1` to each `asked` and `told` line on the list,
   or raise its number. Replace the ledger's `list` line with one line that
   numbers the items, so that a later turn knows what "2 yes" answers:

   ```text
   - 2026-11-16T17:00Z list 1 release webapp; 2 question [Billing rollout](toastty://task/<id>); 3 offer safari-check; 4 rule unblocking-parents; 5 done [Assess the export API](toastty://task/<id>).
   ```

5. **Tell** the user the whole list in one message. Each item is one line:
   its number; its task as a link, or its project when it has no task; what
   waits; and the answer you suggest. Add the mark of step 3 to the item.
   Show the Moving group too, although its tasks need nothing from the user.
   Use this default form, and keep it the same from day to day. Leave out a
   group that has no items, and write nothing else about the items:

   ```markdown
   5 items wait for you; the oldest waits 4 days. Answer with the number, such as "2 yes".

   **Blocks work you started**

   1. webapp: 5 merged tasks wait in To ship, the oldest for 4 days. Suggested: start the release now. *On 3 lists, no answer.*
   2. [Billing rollout](toastty://task/<id>): canary at 5% or 20%? Suggested: 5%.

   **Offers**

   3. A task for a check of the sign-up page in Safari. Suggested: yes, in webapp. *List 2 of 3.*

   **Closes by default**

   4. Keep the Unblocking rule about parent tasks? With no answer, the rule stays.
   5. [Assess the export API](toastty://task/<id>): you have its answer, and nothing remains. With no answer, it is marked Done at the next list.

   **Moving**

   - [Finish the rollout](toastty://task/<id>) continues the billing migration.

   Dropped after 3 lists: a task for the local test fallback.
   ```

   The Talking section of `policy.md` can change this form, such as the
   order, a group for each project, or another field. A rule there wins over
   the default. A review can propose such a rule when `friction.md` shows
   that the user missed an item of the list; see `references/improving.md`.
6. **Nothing waits:** no item is in Blocks work you started, Offers or
   Closes by default. Write the `list` line. When this list dropped an offer,
   tell the user in the Dropped line. When it marked a task Done, name those
   tasks in one line. When it did neither, mark the turn quiet if nothing
   else needs the user, and answer only "Nothing needs you."

When a review follows the list in the same turn, it numbers its proposals
after the list's last number. When the user answers with a number, find the
item in the `list` line or in the `asked review` line, and act on it as the
section that asked says.
