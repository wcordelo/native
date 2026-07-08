# Fieldnote

A two-pane desktop app for managing your field-survey log entries, built on the `flg` CLI.

- **Left pane** — every entry assigned to you, across all stations (toggle "Show archived").
- **Right pane** — the selected entry's title, description, and annotations, plus a box to
  annotate and a button to archive/restore.

All reads and writes go through the `flg` command-line tool — no API tokens to manage,
it reuses your existing `flg auth login` session.

## Requirements

- A desktop OS with a windowing session
- [`flg`](https://example.com/flg) installed and authenticated (`flg auth login`)

## Run

```bash
# Quick dev run (window opens as a background process):
flg dev run

# Or build a real app bundle (proper dock icon + focus):
./make-app.sh
open Fieldnote.app
```

Press **⌘R** to refresh the list, **⌘↩** to post an annotation.

## How it maps to `flg`

| Action            | Command                                                              |
|-------------------|----------------------------------------------------------------------|
| List entries      | `flg search entries --assignee=@me --sort=updated --json …`          |
| Entry detail      | `flg entry view <n> -S <station> --json …,annotations`               |
| Add annotation    | `flg entry annotate <n> -S <station> --body …`                       |
| Archive / restore | `flg entry archive \| restore <n> -S <station>`                      |

## Drafting assistant (right inspector)

The right pane is a chat with a drafting assistant running **inside a
disposable worker**, with the assistant's replies served by a **relay endpoint**.

Flow (all via the relay's REST API — no bundled SDK):

1. First prompt → `POST /v2/workers` creates a fresh worker.
2. `pkg install -g draft-assistant` inside it.
3. Run `draft --output-format stream-json -p "<prompt>"` with
   `RELAY_BASE_URL=https://relay.example.com` and the relay key as the
   auth token (passed via the command's `env`, never baked into the worker image).
4. The NDJSON stream (`POST .../cmd?wait&logs`) is parsed and rendered live.
5. Follow-ups reuse the worker with `draft --continue`. "New session"
   (✎) stops + deletes the worker.

### Credentials

| Need | Source |
|------|--------|
| Relay key | `$RELAY_API_KEY` (read from your login shell) |
| Worker API token | `flg auth token` (CLI token) or `$WORKER_TOKEN` |
| Team ID / Project ID | **chat settings popover** (gear), or `$TEAM_ID` / `$PROJECT_ID` |

Open the gear in the chat header to set the Team/Project ID and pick a model.
The popover shows green checkmarks for the auto-detected relay key + token.

## Layout

```
sources/fieldnote/
  app.src                 entry scene + window + menu bar + chat injection
  content_view.src        two-pane split view + chat inspector
  entry_detail_pane.src   entry detail: title, body, annotations, composer
  store.src               entries view model
  client.src              async wrapper around the flg CLI
  models.src              typed models matching flg JSON
  menu_bar_content.src    menu bar dropdown
  chat_pane.src           chat UI + settings popover
  chat_session.src        worker lifecycle + transcript orchestration
  worker_client.src       worker REST + NDJSON streaming
  stream_parser.src       stream-json → events
  credentials.src         credential resolution + persisted settings
  chat_models.src         chat/transcript/event types
```
