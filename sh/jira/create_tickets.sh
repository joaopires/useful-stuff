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
#   -h : Show this help message
#
# CSV Columns expected:
#   Issue Type, Summary, Description, Priority, Story Points, Labels, Parent
# ==============================================================================

# Function to show help
show_help() {
    echo "Jira Ticket Creator Script (v3 REST API)"
    echo ""
    echo "Usage:"
    echo "  export JIRA_AUTH=\"your-email@example.com:your-api-token\""
    echo "  $0 [-d] [-h] <csv_filepath> <jira_organization> <project_key>"
    echo ""
    echo "Flags:"
    echo "  -d : Dry-run mode (prints JSON payload without creating tickets)"
    echo "  -h : Show this help message"
    echo ""
    echo "Arguments:"
    echo "  <csv_filepath>      Path to the CSV file containing ticket data"
    echo "  <jira_organization> Your Jira domain (e.g., 'company' or 'company.atlassian.net')"
    echo "  <project_key>       The Jira project key (e.g., 'PROJ')"
    echo ""
    echo "CSV Columns expected:"
    echo "  Issue Type, Summary, Description, Priority, Story Points, Labels, Parent"
}

# Parse flags
DRY_RUN=false
while getopts "dh" opt; do
    case ${opt} in
        d) DRY_RUN=true ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done
shift $((OPTIND-1))

CSV_FILE="$1"
DOMAIN="$2"
PROJECT_KEY="$3"

# Check arguments
if [ -z "$CSV_FILE" ] || [ -z "$DOMAIN" ] || [ -z "$PROJECT_KEY" ]; then
    echo "❌ Error: Missing arguments."
    show_help
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
    jq -r '.[] | select(.name == "Story point estimate") | .id' | head -n 1)

if [ -z "$STORY_POINTS_ID" ]; then
    echo "⚠️  Warning: Could not find 'Story Points' field ID automatically. Story points will be skipped."
    # You might want to hardcode it here if you know it, e.g. STORY_POINTS_ID="customfield_10016"
else
    echo "✅ Found Story Points field ID: $STORY_POINTS_ID"
fi

echo "🚀 Starting ticket creation for project: $PROJECT_KEY"

# Parse CSV to JSON using Python for robust handling of quotes and commas
# Also converts Description to Atlassian Document Format (ADF)
RECORDS_JSON=$(python3 -c "
import csv, json, sys

def to_adf_content(text):
    if not text:
        return []
    
    import re
    # Pre-process text to normalize common patterns into lines
    # 1. Ensure DoD: starts on a new line if it's not already
    text = re.sub(r'([^ \n])\s*(DoD:|Acceptance Criteria:)', r'\1\n\2', text)
    # 2. Ensure - bullet points start on new lines
    text = re.sub(r'([^- \n])\s*- ', r'\1\n- ', text)
    
    content = []
    lines = text.splitlines()
    current_list = None
    
    for line in lines:
        clean_line = line.strip()
        if not clean_line:
            current_list = None
            continue
            
        if clean_line.startswith('-'):
            if current_list is None:
                current_list = {'type': 'bulletList', 'content': []}
                content.append(current_list)
            
            item_text = clean_line.lstrip('-').strip()
            current_list['content'].append({
                'type': 'listItem',
                'content': [{
                    'type': 'paragraph',
                    'content': [{'type': 'text', 'text': item_text}]
                }]
            })
        else:
            current_list = None
            
            # Pattern to match boldable headings
            header_match = re.search(r'(DoD:|Acceptance Criteria:)', clean_line)
            
            if header_match:
                header_text = header_match.group(1)
                parts = clean_line.split(header_text, 1)
                
                if parts[0].strip():
                    content.append({
                        'type': 'paragraph',
                        'content': [{'type': 'text', 'text': parts[0].strip()}]
                    })
                
                header_content = [{'type': 'text', 'text': header_text, 'marks': [{'type': 'strong'}]}]
                if parts[1].strip():
                    header_content.append({'type': 'text', 'text': ' ' + parts[1].strip()})
                    
                content.append({
                    'type': 'paragraph',
                    'content': header_content
                })
            else:
                content.append({
                    'type': 'paragraph',
                    'content': [{'type': 'text', 'text': clean_line}]
                })
            
    return content

try:
    with open(sys.argv[1], mode='r', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        data = []
        for row in reader:
            desc = row.get('Description', '')
            row['DescriptionADF'] = {'type': 'doc', 'version': 1, 'content': to_adf_content(desc)}
            data.append(row)
        print(json.dumps(data))
except Exception as e:
    print(f'Error parsing CSV: {e}', file=sys.stderr)
    sys.exit(1)
" "$CSV_FILE")

if [ $? -ne 0 ]; then
    echo "❌ Error: Failed to parse CSV."
    exit 1
fi

# Iterate over each record in the JSON array
echo "$RECORDS_JSON" | jq -c '.[]' | while read -r record; do
    # Extract fields from the JSON record
    ISSUE_TYPE=$(echo "$record" | jq -r '."Issue Type" // empty')
    SUMMARY=$(echo "$record" | jq -r '.Summary // empty')
    DESCRIPTION_ADF=$(echo "$record" | jq -c '.DescriptionADF')
    PRIORITY=$(echo "$record" | jq -r '.Priority // empty')
    STORY_POINTS=$(echo "$record" | jq -r '."Story Points" // empty')
    LABELS_RAW=$(echo "$record" | jq -r '.Labels // empty')
    PARENT_KEY=$(echo "$record" | jq -r '.Parent // empty')

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
        --arg parent "$PARENT_KEY" \
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
        else . end |
        if $parent != "" then
            .fields.parent = { key: $parent }
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
