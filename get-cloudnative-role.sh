#!/bin/bash

PROFILE="adm-tosin.ojo"
OUTPUT_FILE="AWS-roles-report.csv"

# Fetch Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query 'Account' --output text)

# Check if the Account ID was successfully fetched
if [ -z "$ACCOUNT_ID" ]; then
    echo "Failed to fetch AWS Account ID. Exiting."
    exit 1
fi

# Initialize the CSV file with headers
echo "Account ID,Role Name,Description,Trusted Entities,ARN,Last Activity" > $OUTPUT_FILE

# Fetch and process roles
list_roles() {
    marker=""
    while : ; do
        if [[ -z "$marker" ]]; then
            result=$(aws iam list-roles --profile "$PROFILE" 2>&1)
        else
            result=$(aws iam list-roles --profile "$PROFILE" --marker "$marker" 2>&1)
        fi

        # DEBUG: Print raw AWS CLI output
        echo "DEBUG: $result"

        roles=$(echo "$result" | jq -rc '.Roles[]?' 2>/dev/null)
        
        if [[ -z "$roles" ]]; then
            echo "Error or no more IAM Roles: $result"
            break
        fi

        echo "$roles" | while IFS= read -r role; do
            role_name=$(echo "$role" | jq -r '.RoleName')
            description=$(echo "$role" | jq -r '.Description // ""')
            trust_relationship=$(echo "$role" | jq -r '.AssumeRolePolicyDocument.Statement[].Principal.Service // ""')
            arn=$(echo "$role" | jq -r '.Arn')
            last_used=$(aws iam get-role --role-name "$role_name" --profile "$PROFILE" --query 'Role.RoleLastUsed.LastUsedDate' --output text)
            
            # Check if last_used is a valid date, if not set to "N/A"
            if ! date -d "$last_used" &>/dev/null; then
                last_used="N/A"
            fi

            echo "$ACCOUNT_ID,$role_name,\"$description\",\"$trust_relationship\",$arn,$last_used" >> $OUTPUT_FILE
        done

        marker=$(echo "$result" | jq -r '.Marker // ""' 2>/dev/null)
        [[ -z "$marker" || "$marker" == "null" ]] && break
    done
}

# List Roles and their attributes
list_roles

echo "Report generated and saved to $OUTPUT_FILE"
