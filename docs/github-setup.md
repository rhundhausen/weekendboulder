# GitHub setup

Manual steps in the GitHub UI to get the nightly workflows running. Do them in order.

## 1. The repository

The code lives in `rhundhausen/weekendboulder`. Commit to `main` and push normally.

## 2. Default branch

Settings > General > Default branch: `main`. The nightly schedule only runs on the default branch.

## 3. Enable Actions

Settings > Actions > General:

- Actions permissions: allow all actions, or at least actions created by GitHub (`actions/checkout`, `actions/upload-artifact`).
- Workflow permissions: either setting works, because `ingest.yml` and `refine.yml` ask for `contents: write` themselves. Read and write is not required.

If `main` gets a branch protection rule or ruleset later, allow `github-actions[bot]` to push to it, or the nightly data commit will be rejected.

## 4. Repository secrets

Settings > Secrets and variables > Actions > New repository secret. The names must match exactly. The repo starts with no sources, so no API key is needed until a source that uses it is set to `running`:

| Secret | Needed for |
| --- | --- |
| `TICKETMASTER_KEY` | Ticketmaster sources |
| `GOOGLE_CALENDAR_API_KEY` | Google Calendar sources. A Google Cloud API key with the Google Calendar API enabled, restricted to that API |
| `BANDSINTOWN_APP_ID` | Bandsintown, once an app id is approved |
| `EVENTBRITE_TOKEN` | Eventbrite (adapter is disabled) |
| `SEATGEEK_CLIENT_ID` | SeatGeek (adapter is disabled) |
| `SONGKICK_API_KEY` | Songkick (adapter is disabled) |
| `RESEND_API_KEY` | The report emails. A Resend API key (resend.com > API Keys, "Sending access") |
| `REPORT_EMAIL` | The report emails. Where they go, and where replies go. One address, or several separated by commas |

The emails come from `WeekendBoulder Reports <reports@weekendboulder.com>`, and replies go to `REPORT_EMAIL`. The sender is set in `ingestion/scripts/lib/Report.ps1`, not in a secret; weekendboulder.com must be verified in Resend and `RESEND_API_KEY` should be a key scoped to that domain.

A secret you don't create reaches the scripts as empty, and a source that needs it fails with a warning while the rest run. Without `RESEND_API_KEY` or `REPORT_EMAIL`, the "Email the report" step warns and sends nothing.

## 5. Prove the data commit with one source

Before the midnight (Boulder time) schedule runs on its own, add at least one `running` source to `ingestion/sources.json` (see [sources.md](sources.md)), then:

1. Actions > ingest > Run workflow, branch `main`, with a source name in `source` (or blank for every running source). Leave it blank the very first time, so the raw file starts with every source.
2. When it finishes, check:
   - The run is green and the `out` artifact holds `<source name>.json` and `run.json`.
   - `main` has a new commit by "WeekendBoulder bot" titled `data: raw ingest YYYY-MM-DD [skip ci]` that changes only `data/raw-events.json`, and Cloudflare skipped it.
3. Refine starts by itself when ingest finishes (Actions > refine; it can also be run by hand, branch `main`). When it finishes, check:
   - The run is green and its log starts with the raw file's `asOf` and source count.
   - `main` has a new commit titled `data: nightly refine YYYY-MM-DD` that changes only `data/events.json`, `data/archive/`, `data/links.json`, `data/city-lookup.json`, and `data/meta.json`, and its "Workers Builds: weekendboulder" check deployed the site.
   - The test workflow did not run for either commit.
4. If a commit step fails with a permission error, recheck step 3.

After that, leave ingest's schedule to run nightly at midnight Boulder time; refine follows each ingest run. GitHub turns off scheduled workflows in a public repo after 60 days with no repository activity; the nightly data commits count as activity, so this only matters if ingest stops committing.
