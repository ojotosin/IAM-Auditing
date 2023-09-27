#!/bin/bash

PROFILE="adm-tosin.ojo"
OUTPUT_FILE="AWS-230927-permissionreport-iLearn.csv"

# Fetch Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query 'Account' --output text)

# Check if the Account ID was successfully fetched
if [ -z "$ACCOUNT_ID" ]; then
    echo "Failed to fetch AWS Account ID. Exiting."
    exit 1
fi

# Initialize the CSV file with headers
echo "Account ID,Entity Type,Entity Name,Group,Active Key Age,Last Used (Days),Console Access,Policy Type,Policy,PolicyARN" > $OUTPUT_FILE

# Calculate the difference in days between two dates
date_diff() {
    local d1="$1"
    local d2="$2"
    d1=$(date -d "$d1" +%s)
    d2=$(date -d "$d2" +%s)
    echo $(( (d2 - d1) / 86400 ))
}

list_users_with_groups_policies() {
    marker=""
    while : ; do
        if [[ -z "$marker" ]]; then
            result=$(aws iam list-users --profile "$PROFILE" 2>&1)
        else
            result=$(aws iam list-users --profile "$PROFILE" --marker "$marker" 2>&1)
        fi

        users=$(echo "$result" | jq -r '.Users[] | "\(.UserName)"' 2>/dev/null)

        if [[ -z "$users" ]]; then
            echo "Error or no more IAM Users: $result"
            break
        fi

        for user in $users; do
            user_name=$(echo "$user" | tr -d '[:space:]')
            user_groups=$(aws iam list-groups-for-user --profile "$PROFILE" --user-name "$user_name" --query 'Groups[].GroupName' --output text)

            active_key_age="N/A"
            last_used="N/A"
            console_access="No"

            # Get active access key creation date
            key_creation_date=$(aws iam list-access-keys --profile "$PROFILE" --user-name "$user_name" --query 'AccessKeyMetadata[?Status==`Active`].CreateDate' --output text)
            if [[ "$key_creation_date" != "None" && ! -z "$key_creation_date" ]]; then
                current_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                active_key_age=$(date_diff "$key_creation_date" "$current_date")
            fi

            # Get last used date
            last_used_date=$(aws iam get-access-key-last-used --profile "$PROFILE" --access-key-id $(aws iam list-access-keys --profile "$PROFILE" --user-name "$user_name" --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' --output text) --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null)
            if [[ "$last_used_date" != "None" && ! -z "$last_used_date" ]]; then
                current_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                last_used=$(date_diff "$last_used_date" "$current_date")
            else
                last_used="N/A"
            fi

            # Check for console access
            if aws iam get-login-profile --profile "$PROFILE" --user-name "$user_name" &> /dev/null; then
                console_access="Yes"
            fi

            if [[ -z "$user_groups" ]]; then
                # Users with no groups
                user_policies=$(aws iam list-attached-user-policies --profile "$PROFILE" --user-name "$user_name" --query 'AttachedPolicies[*].[PolicyName,PolicyArn]' --output text)
                
                if [[ -z "$user_policies" ]]; then
                    echo "$ACCOUNT_ID,User,$user_name,None,$active_key_age,$last_used,$console_access,,," >> $OUTPUT_FILE
                else
                    while IFS=$'\t' read -r policy_name policy_arn; do
                        echo "$ACCOUNT_ID,User,$user_name,None,$active_key_age,$last_used,$console_access,Attached,$policy_name,$policy_arn" >> $OUTPUT_FILE
                    done <<< "$user_policies"
                fi
            else
                # Users with groups
                for group in $user_groups; do
                    group_policies=$(aws iam list-attached-group-policies --profile "$PROFILE" --group-name "$group" --query 'AttachedPolicies[*].[PolicyName,PolicyArn]' --output text)

                    if [[ -z "$group_policies" ]]; then
                        echo "$ACCOUNT_ID,User,$user_name,$group,$active_key_age,$last_used,$console_access,,," >> $OUTPUT_FILE
                    else
                        while IFS=$'\t' read -r policy_name policy_arn; do
                            echo "$ACCOUNT_ID,User,$user_name,$group,$active_key_age,$last_used,$console_access,Attached,$policy_name,$policy_arn" >> $OUTPUT_FILE
                        done <<< "$group_policies"
                    fi
                done
            fi
        done

        marker=$(echo "$result" | jq -r '.Marker' 2>/dev/null)
        [[ -z "$marker" || "$marker" == "null" ]] && break
    done
}

# List Users with their groups and associated policies
list_users_with_groups_policies

echo "Report generated and saved to $OUTPUT_FILE"
