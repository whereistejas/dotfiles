---
name: m365
description: Read the user's Microsoft 365 data — Teams chats and channel messages, Outlook mail and calendar, SharePoint/OneDrive files, people lookup — through the claude.ai Microsoft 365 connector, driven by headless Claude Code. Read-only. Use when asked about Teams messages, emails, meetings, or M365 files.
---

# m365

The Microsoft 365 tenant has approved Anthropic's Microsoft 365 connector, but its OAuth flow only
completes on claude.ai, so pi cannot connect to it as an MCP server. Claude Code logged
in to the same claude.ai account can. `scripts/m365` runs `claude -p` (Haiku by default)
with one connector tool allowed, has it make one call with your exact arguments, and
prints the raw tool result taken from the stream-json events. The model never retypes
the data, and the script exits 3 if the model changed the arguments or the call count.

```bash
M=~/.pi/agent/skills/m365/scripts/m365
$M tools                         # the allowed read-only tools
$M schema chat_message_search    # description + input schema
$M call chat_message_search '{"query":"*","afterDateTime":"today","limit":25,"offset":0}'
```

Exit codes: 0 ok, 1 usage or `claude` failure, 2 the tool returned an error, 3 the model
did not make exactly the requested call.

Each call takes ~10–20 s and costs well under a cent. Run independent calls (pages,
time slices) in parallel. Set `M365_MODEL` or `M365_TIMEOUT` (seconds, default 300) to
override.

## Read-only

Only these tools are allowed: `chat_message_search`, `teams_list_chats`,
`teams_list_teams`, `teams_list_channels`, `teams_list_channel_messages`,
`read_resource`, `outlook_email_search`, `outlook_calendar_search`,
`outlook_find_available_time`, `find_meeting_availability`, `sharepoint_search`,
`sharepoint_folder_search`, `search_people`, `get_me`, `get_granted_scopes`. Sending,
drafting, deleting and uploading tools are explicitly denied. Do not add them without the
user asking.

## Output

Search tools print NDJSON: one object per result, then a final
`{"moreResults": true, "nextOffset": N}` line while more pages remain. Results carry a
`uri`; pass it to `read_resource` (`{"uri": "..."}`) for the full body.

## Pagination limits

- `limit` is capped at 25; higher values fail validation.
- `offset` is capped at 1000, so one query returns at most ~1000 results. A truncated
  run looks like an exhausted one. Slice long windows by `afterDateTime` /
  `beforeDateTime` (Teams: keep slices under ~6 h on busy days).
- Chat search has been observed returning 19 per page, not 25. Follow `nextOffset`; don't
  compute pages.
- Graph can return 429 mid-run. Treat it as throttling and retry, not as the end.

## Setup and failures

Requires `claude` logged in to the claude.ai account the connector is approved for (`claude auth status` →
`"authMethod": "claude.ai"`) and the Microsoft 365 connector connected at claude.ai →
Settings → Connectors. "OAuth session expired" means run `claude auth login`. A
connector auth error means reconnect it on claude.ai.
