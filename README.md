# Kapi Action

A GitHub Action that runs [kapi](https://github.com/neokapi/neokapi) commands — catch up translations, gate content quality, plan cost — and delivers the results — as a commit, a pull request, or a report on the PR that caused the work.

## Prerequisites

This action requires the `kapi` CLI to be installed. Use [`neokapi/setup-kapi@v1`](https://github.com/neokapi/setup-kapi) to install it (the bowrain plugin is included by default), or add it to `PATH` yourself.

## Usage

### Bring translations up to date

`kapi up` runs the kapi loop, and is the Action's default. In a server-connected project — a recipe with a `server:` block — it pushes, catches up on the Bowrain server (org keys, shared TM, team review), and pulls the produced targets back. With no server it runs the same loop locally.

```yaml
name: Translations
on:
  schedule:
    - cron: "0 6 * * 1-5" # weekdays at 06:00 UTC
  workflow_dispatch:

permissions:
  contents: write

jobs:
  up:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: neokapi/setup-kapi@v1

      - uses: neokapi/kapi-action@v1

      # The action reports; delivery is your step. Any commit action works —
      # or plain git. See "Delivering the changes" for the PR-based recipe.
      - uses: stefanzweifel/git-auto-commit-action@v5
        with:
          commit_message: "chore: update translations via kapi"
```

### Outcomes

A `kapi up` run ends in one of three states, and the Action treats them differently:

| Run state | What it means | What the Action does |
|---|---|---|
| **converged** | Every gated scope cleared its ship gate — the project is up to date | Reports the produced translations (`has-changes`, `changed-files`) for your delivery step |
| **parked** | Work remains that the loop could not carry to the gate (a failing check, an unreachable gate) | Reports what it *did* catch up, and annotates the run with the parked locales. This is normal pending work, not a failure |
| **failed / canceled** | The run broke (a provider outage, a server error, a cancel) | `kapi up` exits non-zero, the step fails, **`has-changes` never reports** — a broken run must not hand your delivery step partial work |

Parked is the interesting one: partial progress is real progress, so the default is to report it and warn rather than throw it away. To block instead:

```yaml
- uses: neokapi/kapi-action@v1
  with:
    fail-on-parked: "true"
```

### How the loop works

`kapi up` treats the recipe as the desired state — the languages the project targets, and the ship gates that define *shippable* — and reconciles the content toward it. Each pass, for every language behind its gate:

1. **Reuse** — exact translation-memory matches fill first, for free.
2. **Translate** — the configured AI provider fills what remains, with the project's terminology and brand context.
3. **Check** — deterministic checks run over what was produced (placeholder integrity, inline tags, do-not-translate terms, untranslated text). A unit with a failing finding counts as *drafted*, not translated — it cannot clear a gate until fixed.

Passes repeat until every language clears its gate, a pass makes no progress, or the pass cap is reached.

```mermaid
flowchart LR
    S[source changes] --> U[kapi up]
    subgraph PASS ["each pass, per language behind its gate"]
        TM["1 · reuse<br/>TM exact matches"] --> AI["2 · translate<br/>AI + terminology"] --> CK["3 · check<br/>placeholders · terms · tags"]
    end
    U --> PASS
    CK -->|every gate met| CV["up to date<br/>changes ready to deliver"]
    CK -->|needs a person| PK["parked<br/>the review queue"]
    PK --> RV["review & approve<br/>recorded in .kapi-state.json"]
    RV -.->|next run sees it| U
```

**Parked work is the review queue, not an error.** What the machine couldn't decide waits for a person: review the wording, approve or fix it, and the decision is recorded — in the committed `.kapi-state.json` state store, or on the connected server. Approvals raise the `reviewed` coverage the ship gate measures, so the next run and the next gate see them. `kapi check --ship` (see [Gate pull requests](#gate-pull-requests-on-content-quality)) is what enforces the bar at release time.

The kapi up report (outcome, passes, parked locales) is always written to the job summary. Under the hood the Action runs `kapi up --json`, an NDJSON stream — one convergence event per line, closed by a single `{"type":"result", ...}` record. That record is the contract; the events are the log. It becomes the `outcome`, `passes`, and `parked-locales` outputs.

### Delivering the changes

The action never commits, pushes, or opens PRs. It leaves the produced
translations in the working tree and reports them (`has-changes`,
`changed-files`), so delivery is a step you own — which also means the token,
the authorship, and the review policy are yours, stated in your workflow
instead of hidden in ours.

Straight commit to the current branch:

```yaml
- uses: neokapi/kapi-action@v1
  id: kapi

- uses: stefanzweifel/git-auto-commit-action@v5
  if: steps.kapi.outputs.has-changes == 'true'
  with:
    commit_message: "chore: update translations via kapi"
```

As a pull request — the reviewable unit, and the shape that respects the
"machine proposes, a person decides" model:

```yaml
- uses: neokapi/kapi-action@v1
  id: kapi

- uses: peter-evans/create-pull-request@v7
  if: steps.kapi.outputs.has-changes == 'true'
  with:
    commit-message: "chore: update translations via kapi"
    title: "Translations: kapi up"
    branch: kapi/up
```

**One GitHub behavior to know:** anything pushed with the workflow-provided
`GITHUB_TOKEN` triggers **no workflows** — no CI on the commit, no checks on
the created PR, no deploy when it lands on main. That is GitHub loop
prevention, not a kapi limitation. If CI or deploys should react to the
delivered translations, give the delivery step a fine-grained PAT or a GitHub
App token instead (both delivery actions above accept a `token:` input).

### Plan mode: the cost of a change, on its PR

`plan: "true"` dry-runs the kapi loop — pending work, TM leverage, and a token estimate, with no writes and no provider calls (so it needs no API keys). With `pr-comment: "true"` on a pull-request event, the plan lands as one sticky comment that re-runs update in place:

```yaml
name: Translation plan
on:
  pull_request:
    paths: ["src/locales/en/**", "content/**"]

permissions:
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: neokapi/setup-kapi@v1
      - uses: neokapi/kapi-action@v1
        with:
          plan: "true"
          pr-comment: "true"
```

> "This change leaves **42 unit(s)** of pending translation work: 30 recoverable from TM, 12 for AI (~450 tokens estimated)."

### Gate pull requests on content quality

`command: check` with `--ship` is the release bar: the project's bound quality gates (brand, terminology, QA) plus its ship/source coverage gates. An unmet gate exits `3`, which the Action surfaces as a distinct **"gate unmet"** annotation (not a generic failure) and as the `gate` output:

```yaml
name: Ship gate
on:
  pull_request:
    paths: ["content/**", "src/locales/**"]

permissions:
  pull-requests: write

jobs:
  ship-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: neokapi/setup-kapi@v1
      - uses: neokapi/kapi-action@v1
        with:
          command: check
          args: "--ship"
          commit: "false"
          pr-comment: "true"
```

Ordinary builds never fail on target-language drift — a locale that is behind is pending work, not an error. `check --ship` is the explicit, opt-in enforcement point.

### Run any other kapi command

`command` takes any kapi subcommand — the Action stays a general runner. The loop outputs (`outcome`, `passes`, `parked-locales`) are only populated for `up`.

```yaml
- uses: neokapi/kapi-action@v1
  with:
    command: run
    args: "translate"
    project: "kapi.yaml"
    paths: "src/locales/"
```

This runs `kapi run -p kapi.yaml translate`.

### Caching

The loop runs incrementally via the project's `.kapi/cache` (block store, extractions), which is gitignored and therefore rebuilt on every fresh runner. Restore it across runs to skip re-extraction:

```yaml
- uses: actions/cache@v5
  with:
    path: .kapi/cache
    key: kapi-cache-${{ hashFiles('kapi.yaml', 'src/locales/en/**') }}
    restore-keys: kapi-cache-
```

Server-connected projects don't need this — the project state lives on the server.

## Inputs

| Input | Default | Description |
|---|---|---|
| `command` | `up` | Kapi subcommand to execute |
| `args` | | Additional arguments |
| `project` | | Path to the `kapi.yaml` recipe (`-p` flag) |
| `plan` | `false` | With `command: up`: dry run — pending work, TM leverage, token estimate; no writes, no provider calls |
| `fail-on-parked` | `false` | With `command: up`, fail the workflow when the run parks instead of reporting partial progress |
| `pr-comment` | `false` | Sticky report comment on pull-request events |
| `token` | `${{ github.token }}` | Token for the sticky PR comment |
| `paths` | | Space-separated paths to scan for changes (whole working tree if empty) |

## Outputs

| Output | Description |
|---|---|
| `status` | `success`, `no-changes`, or `failed` |
| `outcome` | With `command: up`: `converged` or `parked` (a failed run fails the step, so it never reaches an output) |
| `passes` | With `command: up`: how many reconciliation passes the run took |
| `parked-locales` | With `command: up`: comma-separated locales still short of their gate |
| `gate` | With `command: check`: `pass` or `fail` |
| `plan-missing` / `plan-tm-exact` / `plan-ai-remaining` / `plan-token-estimate` | With `plan: true`: the plan totals |
| `has-changes` | Whether the run left changes in the working tree for your delivery step |
| `changed-files` | Newline-separated paths the run changed |

## Permissions

The action itself needs no write permissions. Your delivery step needs `contents: write` (plus `pull-requests: write` for PR delivery); `pr-comment` needs `pull-requests: write`.

## License

Apache-2.0 - see [LICENSE](LICENSE).
