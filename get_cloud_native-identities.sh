#!/bin/bash

PROFILE="adm-tosin.ojo"
OUTPUT_FILE="AWS-230926-permissionreport-security.csv"

# Initialize the CSV file with headers
echo "Entity Type,Entity Name,Active Key Age,Last Used,Console Access,Policy Type,Policy,PolicyARN" > $OUTPUT_FILE

# Calculate the difference in days between two dates
date_diff() {
    local d1="$1"
    local d2="$2"
    d1=$(date -d "$d1" +%s)
    d2=$(date -d "$d2" +%s)
    echo $(( (d2 - d1) / 86400 ))
}

# Function to handle listing of Users, Groups, and Roles along with their policies
list_identities_with_policies() {
    local type="$1"
    local list_command="$2"
    local policy_command="$3"
    local jq_query="$4"

    marker=""
    while : ; do
        if [[ -z "$marker" ]]; then
            result=$(aws iam "$list_command" --profile "$PROFILE" 2>&1)
        else
            result=$(aws iam "$list_command" --profile "$PROFILE" --marker "$marker" 2>&1)
        fi

        identities=$(echo "$result" | jq -r "$jq_query" 2>/dev/null)

        if [[ -z "$identities" ]]; then
            echo "Error or no more IAM $type: $result"
            break
        fi

        for identity in $identities; do
            identity_name=$(echo "$identity" | tr -d '[:space:]')  # Remove any extra spaces

            # Skip if identity name is empty or not valid
            if [[ -z "$identity_name" || ! "$identity_name" =~ ^[a-zA-Z0-9+=,.@_-]+$ ]]; then
                echo "Skipping invalid ${type} name: $identity_name"
                continue
            fi

            active_key_age="N/A"
            last_used="N/A"
            console_access="No"

            if [[ "$type" == "User" ]]; then
                # Get active access key creation date
                key_creation_date=$(aws iam list-access-keys --profile "$PROFILE" --user-name "$identity_name" --query 'AccessKeyMetadata[?Status==`Active`].CreateDate' --output text)
                if [[ "$key_creation_date" != "None" && ! -z "$key_creation_date" ]]; then
                    current_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                    active_key_age=$(date_diff "$key_creation_date" "$current_date")
                fi

                # Get last used date
                last_used_date=$(aws iam get-access-key-last-used --profile "$PROFILE" --access-key-id $(aws iam list-access-keys --profile "$PROFILE" --user-name "$identity_name" --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' --output text) --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null)
                if [[ "$last_used_date" != "None" && ! -z "$last_used_date" ]]; then
                    last_used="$last_used_date"
                fi

                # Check for console access
                if aws iam get-login-profile --profile "$PROFILE" --user-name "$identity_name" &> /dev/null; then
                    console_access="Yes"
                fi
            fi

            # Fetch attached policies
            policies=$(aws iam "$policy_command" --profile "$PROFILE" --${type,,}-name "$identity_name" --query 'AttachedPolicies[*].[PolicyName,PolicyArn]' --output text)

            if [[ -z "$policies" ]]; then
                # Handle entities without policies
                echo "$type,$identity_name,$active_key_age,$last_used,$console_access,,," >> $OUTPUT_FILE
            else
                # Handle entities with policies
                while IFS=$'\t' read -r policy_name policy_arn; do
                    echo "$type,$identity_name,$active_key_age,$last_used,$console_access,Attached,$policy_name,$policy_arn" >> $OUTPUT_FILE
                done <<< "$policies"
            fi
        done

        marker=$(echo "$result" | jq -r '.Marker' 2>/dev/null)
        [[ -z "$marker" || "$marker" == "null" ]] && break
    done
}

# List Users, Groups, and Roles with their policies
list_identities_with_policies "User" "list-users" "list-attached-user-policies" '.Users[] | "\(.UserName)"'
list_identities_with_policies "Group" "list-groups" "list-attached-group-policies" '.Groups[] | "\(.GroupName)"'
list_identities_with_policies "Role" "list-roles" "list-attached-role-policies" '.Roles[] | "\(.RoleName)"'

echo "Report generated and saved to $OUTPUT_FILE"
