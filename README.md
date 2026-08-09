# workflows

Shared public GitHub Actions reusable workflow for Claude Code routines running
across Toni Aquino's Team Vault / squad-kb repos (`toniaquino/*`). Generic CI
orchestration only — no proprietary content, no company data.

## Why this repo is public

GitHub does not support cross-repo `workflow_call` access to a *private* repo
under a personal (non-org) GitHub account. This was confirmed empirically
(2026-08-09): hosting the runner in a private repo and calling it cross-repo
from another private repo failed with `422 workflow was not found`. Public
repos have no such restriction — that's the only reason this exists here
instead of alongside the actual KB content.

## What's in here

- `.github/workflows/reusable-routine-runner.yml` — the shared
  cache/install/clone/run logic every routine workflow calls via
  `workflow_call`, instead of duplicating ~40 lines of boilerplate per squad.

## Usage

From a calling repo's workflow file:

```yaml
jobs:
  my-job:
    uses: toni-aq/workflows/.github/workflows/reusable-routine-runner.yml@main
    with:
      repo_name: some-squad-kb
      prompt_path: .github/prompts/routine-a.md
      model: claude-sonnet-5
      job_display_name: "weekly synthesis"
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      GH_PAT: ${{ secrets.GH_PAT }}
      ATLASSIAN_API_TOKEN: ${{ secrets.ATLASSIAN_API_TOKEN }}
      ATLASSIAN_EMAIL: ${{ secrets.ATLASSIAN_EMAIL }}
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
      DRY_RUN: ${{ secrets.DRY_RUN }}
```

**Use explicit per-secret passthrough, not `secrets: inherit`.** Confirmed
empirically (2026-08-09, `organize-squad-kb` pilot): `secrets: inherit` from
a caller in one GitHub account (`toniaquino`) to this repo's workflow in a
different account (`toni-aq`) resulted in the called job failing before a
runner was even allocated (no logs, ~3-6s failure) -- almost certainly a
required-secrets validation failure, i.e. `inherit` did not reliably carry
the secrets across the account boundary. Switching to explicit per-secret
assignment (as above) fixed it on the first try. `secrets: inherit` may
well work fine for same-owner cross-repo calls; it just isn't proven here
and isn't worth re-testing when the explicit form is equally short and
known-good.

See the workflow file's own header comments for the full input/secret list
and for what it deliberately does NOT support (routine-specific one-off
secrets — see the Routine 8 note).
