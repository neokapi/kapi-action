# Kapi Action

A GitHub Action that runs [kapi](https://github.com/neokapi/neokapi) localization commands and commits the results.

## Prerequisites

This action requires the `kapi` CLI to be installed. Use [`neokapi/setup-kapi@v1`](https://github.com/neokapi/setup-kapi) to install it, or add it to `PATH` yourself.

## Usage

### Bring translations up to date

`kapi up` is the convergence verb, and the Action's default. In a server-connected project — a recipe with a `server:` block, plus the `kapi-bowrain` plugin — it pushes, converges on the Bowrain server (org keys, shared TM, team review), and pulls the produced targets back. With no server it runs the same loop locally.

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
```

### Outcomes

A convergence run ends in one of three states, and the Action treats them differently:

| Run state | What it means | What the Action does |
|---|---|---|
| **converged** | Every gated scope cleared its ship gate | Commits the produced translations |
| **parked** | Work remains that the loop could not carry to the gate (a failing check, an unreachable gate) | Commits what *did* converge, and annotates the run with the parked locales. This is normal pending work, not a failure |
| **failed / canceled** | The run broke (a provider outage, a server error, a cancel) | `kapi up` exits non-zero, the step fails, **nothing is committed** |

Parked is the interesting one: partial progress is real progress, so the default is to commit it and warn rather than throw it away. To block instead:

```yaml
- uses: neokapi/kapi-action@v1
  with:
    fail-on-parked: "true"
```

Under the hood the Action runs `kapi up --json`, an NDJSON stream — one convergence event per line, closed by a single `{"type":"result", ...}` record. That record is the contract; the events are the log. It becomes the `outcome`, `passes`, and `parked-locales` outputs:

```yaml
- uses: neokapi/kapi-action@v1
  id: kapi
  with:
    commit: "false"

- run: |
    echo "outcome: ${{ steps.kapi.outputs.outcome }}"
    echo "passes:  ${{ steps.kapi.outputs.passes }}"
    echo "parked:  ${{ steps.kapi.outputs.parked-locales }}"
```

### Run any other kapi command

`command` takes any kapi subcommand — the Action stays a general runner. The convergence outputs are only populated for `up`.

```yaml
- uses: neokapi/kapi-action@v1
  with:
    command: run
    args: "translate"
    project: "myproject.kapi"
    paths: "src/locales/"
    commit-message: "chore: update translations"
```

This runs `kapi run -p myproject.kapi translate`.

## Inputs

| Input | Default | Description |
|---|---|---|
| `command` | `up` | Kapi subcommand to execute |
| `args` | | Additional arguments |
| `project` | | Path to `.kapi` project file (`-p` flag) |
| `fail-on-parked` | `false` | With `command: up`, fail the workflow when the run parks instead of committing partial progress |
| `commit` | `true` | Whether to commit changes |
| `commit-message` | `chore: update translations via kapi` | Commit message |
| `git-user-name` | `Kapi Bot` | Git committer name |
| `git-user-email` | `bot@kapi.dev` | Git committer email |
| `paths` | | Space-separated paths to stage for commit (all changes if empty) |

## Outputs

| Output | Description |
|---|---|
| `status` | `success`, `no-changes`, or `failed` |
| `outcome` | With `command: up`: `converged` or `parked` (a failed run fails the step, so it never reaches an output) |
| `passes` | With `command: up`: how many reconciliation passes the run took |
| `parked-locales` | With `command: up`: comma-separated locales still short of their gate |
| `committed` | `true` or `false` |
| `commit-sha` | SHA of the created commit (empty if no commit) |

## Permissions

The workflow must have `permissions: contents: write` for the commit step to push changes.

## License

Apache-2.0 - see [LICENSE](LICENSE).
