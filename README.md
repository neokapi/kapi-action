# Kapi Action

A GitHub Action that runs [kapi](https://github.com/neokapi/neokapi) localization commands and commits the results.

## Prerequisites

This action requires the `kapi` CLI to be installed. Use [`neokapi/setup-bowrain@v1`](https://github.com/neokapi/setup-bowrain) to install it, or add it to `PATH` yourself.

## Usage

### Basic: run a kapi flow

```yaml
name: Run translations
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  translate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: neokapi/setup-bowrain@v1
        with:
          token: ${{ secrets.NEOKAPI_GITHUB_TOKEN }}

      - uses: neokapi/kapi-action@v1
        with:
          args: "translate"
          paths: "i18n/ locales/"
```

### With a project file

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

### Without auto-commit (inspect changes only)

```yaml
- uses: neokapi/kapi-action@v1
  id: kapi
  with:
    args: "translate"
    commit: "false"

- run: echo "Status was ${{ steps.kapi.outputs.status }}"
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `command` | `run` | Kapi subcommand to execute |
| `args` | | Additional arguments |
| `project` | | Path to `.kapi` project file (`-p` flag) |
| `commit` | `true` | Whether to commit changes |
| `commit-message` | `chore: update translations via kapi` | Commit message |
| `git-user-name` | `Kapi Bot` | Git committer name |
| `git-user-email` | `bot@kapi.dev` | Git committer email |
| `paths` | | Space-separated paths to stage for commit (all changes if empty) |

## Outputs

| Output | Description |
|---|---|
| `status` | `success`, `no-changes`, or `failed` |
| `committed` | `true` or `false` |
| `commit-sha` | SHA of the created commit (empty if no commit) |

## Permissions

The workflow must have `permissions: contents: write` for the commit step to push changes.

## License

Apache-2.0 - see [LICENSE](LICENSE).
