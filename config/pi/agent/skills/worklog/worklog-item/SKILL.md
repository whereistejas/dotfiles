---
name: worklog-item
description: Track and query the current work item for display in status bars and footers
---

# Worklog Item Tracking

## Overview

Work items are stored in the daily note frontmatter property `current_work_item`. This integrates with the worklog skill's Obsidian vault at `~/build/notes`, allowing you to track what you're currently working on and display it in status bars, footers, or other UI components.

## Getting the Current Work Item

To retrieve the current work item from today's daily note:

```bash
# Get the daily note path first (handles note creation)
DAILY_PATH=$(obsidian vault="notes" daily:path 2>/dev/null)
if [ -n "$DAILY_PATH" ]; then
  obsidian vault="notes" property:read name="current_work_item" path="$DAILY_PATH" 2>/dev/null || echo ""
else
  echo ""
fi
```

This command returns the value of the `current_work_item` property. If the property is not set, the daily note doesn't exist, or if there's an error, it returns an empty string.

## Setting the Current Work Item

To set or update the current work item in today's daily note:

```bash
# Ensure daily note exists first by appending empty content if needed
obsidian vault="notes" daily:append content="" 2>/dev/null

# Get the daily note path
DAILY_PATH=$(obsidian vault="notes" daily:path)

# Set the property
obsidian vault="notes" property:set name="current_work_item" \
  value="JIRA-123: implement feature X" \
  path="$DAILY_PATH"
```

Or as a one-liner:

```bash
obsidian vault="notes" daily:append content="" && \
obsidian vault="notes" property:set name="current_work_item" \
  value="JIRA-123: implement feature X" \
  path="$(obsidian vault=notes daily:path)"
```

**Note:** Obsidian must be running for these commands to work.

## Clearing the Work Item

To clear the current work item (e.g., when you've finished the task):

```bash
obsidian vault="notes" property:set name="current_work_item" \
  value="" \
  path="$(obsidian vault=notes daily:path)"
```

## Integration Notes

This skill is designed for use by footer/status extensions and other UI components that need to display the current work context.

**Caching recommendations:**
- Cache the result with a TTL similar to jj commit info (5 seconds)
- This prevents excessive calls to the Obsidian API during frequent UI updates
- Return "no work item" or empty string as the default when not set or on error
- Handle errors gracefully to avoid breaking UI components if Obsidian is not running
