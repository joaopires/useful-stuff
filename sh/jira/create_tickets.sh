#!/bin/bash

# ==============================================================================
# Jira Ticket Creator Script (v3 REST API)
# 
# Usage:
#   export JIRA_AUTH="your-email@example.com:your-api-token"
#   ./create_tickets.sh [-d] <csv_filepath> <jira_organization> <project_key>
#
# Flags:
#   -d : Dry-run mode (prints JSON payload without creating tickets)
#
# CSV Columns expected:
#   Issue Type, Summary, Description, Priority, Story Points, Labels
# ==============================================================================

# Parse flags
DRY_RUN=false
while getopts "d" opt; do
    case ${opt} in
        d) DRY_RUN=true ;;
        *) echo "Usage: $0 [-d] <csv_filepath> <jira_organization> <project_key>"; exit 1 ;;
    esac
done
shift $((OPTIND-1))

CSV_FILE="$1"
DOMAIN="$2"
PROJECT_KEY="$3"

# Check arguments
if [ -z "$CSV_FILE" ] || [ -z "$DOMAIN" ] || [ -z "$PROJECT_KEY" ]; then
    echo "❌ Error: Missing arguments."
    echo "Usage: $0 [-d] <csv_filepath> <jira_organization> <project_key>"
    echo "Example: $0 -d tasks.csv my-domain PROJ"
    exit 1
fi

# Ensure domain ends with .atlassian.net
if [[ "$DOMAIN" != *".atlassian.net"* ]]; then
    DOMAIN="${DOMAIN}.atlassian.net"
fi

if [ "$DRY_RUN" = true ]; then
    echo "⚠️  Dry-run mode enabled. Tickets will NOT be created."
fi

# Check authentication environment variable
if [ -z "$JIRA_AUTH" ]; then
    echo "❌ Error: JIRA_AUTH environment variable must be set."
    echo "Format: export JIRA_AUTH=\"email:api-token\""
    echo "You can generate an API token at: https://id.atlassian.com/manage-profile/security/api-tokens"
    exit 1
fi

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    echo "❌ Error: File '$CSV_FILE' not found."
    exit 1
fi

# Check for dependencies
if ! command -v jq &> /dev/null; then
    echo "❌ Error: 'jq' is not installed. Please install it (e.g., brew install jq)."
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "❌ Error: 'python3' is not installed. It is required for robust CSV parsing."
    exit 1
fi

echo "🔍 Attempting to find Story Points custom field ID..."
STORY_POINTS_ID=$(curl -s -u "$JIRA_AUTH" \
    "https://$DOMAIN/rest/api/3/field" | \
    jq -r '.[] | select(.name == "Story Points") | .id' | head -n 1)

if [ -z "$STORY_POINTS_ID" ]; then
    echo "⚠️  Warning: Could not find 'Story Points' field ID automatically. Story points will be skipped."
    # You might want to hardcode it here if you know it, e.g. STORY_POINTS_ID="customfield_10016"
else
    echo "✅ Found Story Points field ID: $STORY_POINTS_ID"
fi

echo "🚀 Starting ticket creation for project: $PROJECT_KEY"

# Parse CSV to JSON using Python for robust handling of quotes and commas
RECORDS_JSON=$(python3 -c '
import csv, json, sys
try:
    with open(sys.argv[1], mode="r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        data = [row for row in reader]
        print(json.dumps(data))
except Exception as e:
    print(f"Error parsing CSV: {e}", file=sys.stderr)
    sys.exit(1)
' "$CSV_FILE")

if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to parse CSV."
    exit 1
fi

# Iterate over each record in the JSON array
echo "$RECORDS_JSON" | jq -c '.[]' | while read -r record; do
    # Extract fields from the JSON record
    ISSUE_TYPE=$(echo "$record" | jq -r '."Issue Type" // empty')
    SUMMARY=$(echo "$record" | jq -r '.Summary // empty')
    DESCRIPTION=$(echo "$record" | jq -r '.Description // empty')
    PRIORITY=$(echo "$record" | jq -r '.Priority // empty')
    STORY_POINTS=$(echo "$record" | jq -r '."Story Points" // empty')
    LABELS_RAW=$(echo "$record" | jq -r '.Labels // empty')

    if [ -z "$SUMMARY" ]; then
        echo "⏭️  Skipping row with missing Summary."
        continue
    fi

    echo "📝 Processing: $SUMMARY"

    # Convert labels from string (comma or space separated) to JSON array
    LABELS_JSON=$(echo "$LABELS_RAW" | jq -R '
        if . == "" then [] 
        else split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))
        end')

    # Construct the Atlassian Document Format (ADF) description
    # This is required for Jira Cloud REST API v3
    DESCRIPTION_ADF=$(jq -n --arg desc "$DESCRIPTION" '{
        type: "doc",
        version: 1,
        content: [
            {
                type: "paragraph",
                content: [
                    {
                        text: $desc,
                        type: "text"
                    }
                ]
            }
        ]
    }')

    # Construct the full payload
    # Note: Issues are created with the provided names for issue type and priority.
    # Story points are only added if the ID was found.
    PAYLOAD=$(jq -n \
        --arg project "$PROJECT_KEY" \
        --arg summary "$SUMMARY" \
        --arg type "$ISSUE_TYPE" \
        --arg priority "$PRIORITY" \
        --arg sp "$STORY_POINTS" \
        --arg sp_id "$STORY_POINTS_ID" \
        --argjson description "$DESCRIPTION_ADF" \
        --argjson labels "$LABELS_JSON" \
        '{
            fields: {
                project: { key: $project },
                summary: $summary,
                issuetype: { name: $type },
                priority: { name: $priority },
                description: $description,
                labels: $labels
            }
        } | 
        if $sp_id != "" and $sp != "" then 
            .fields[$sp_id] = ($sp | tonumber) 
        else . end')

    # Send the POST request to Jira (skip if dry-run)
    if [ "$DRY_RUN" = true ]; then
        echo "☁️  Dry-run: Would create '$SUMMARY'. Payload:"
        echo "$PAYLOAD" | jq .
        echo "--------------------------------------------------"
    else
        RESPONSE=$(curl -s -u "$JIRA_AUTH" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            --data "$PAYLOAD" \
            "https://$DOMAIN/rest/api/3/issue")

        # Check if the request was successful
        ISSUE_KEY=$(echo "$RESPONSE" | jq -r '.key // empty')
        if [ -n "$ISSUE_KEY" ]; then
            echo "✅ Created: $ISSUE_KEY (https://$DOMAIN/browse/$ISSUE_KEY)"
        else
            ERROR_MSG=$(echo "$RESPONSE" | jq -r '.errorMessages[0] // .errors | to_entries | .[0].value // "Unknown error"')
            echo "❌ Failed to create ticket: $ERROR_MSG"
            # Optional: print full response for debugging
            # echo "$RESPONSE"
        fi
    fi

done

echo "🏁 All done."
