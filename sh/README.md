# 🛠 Shell Scripts

A collection of useful shell scripts.

## Jira Tools (`/jira`)

### `create_tickets.sh`

A shell script to bulk create Jira tickets from a CSV file using Jira REST API v3. Supports dry-runs and handles Story Points, Labels, and ADF descriptions.

#### Usage

Ensure the script has execution permissions:

```bash
chmod +x jira/create_tickets.sh
```

Run the script:

```bash
export JIRA_AUTH="email@example.com:api-token"
./jira/create_tickets.sh [-d] [-h] <csv_filepath> <jira_organization> <project_key>
```
