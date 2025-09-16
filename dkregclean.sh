#!/bin/bash

REGISTRY_URL="docker-registry.services.sabio.de"
DEFAULT_REPOSITORY="knowledge-file-management"

# If beddu.sh is not present, download it
if [ ! -f beddu.sh ]; then
    curl -O https://raw.githubusercontent.com/mjsarfatti/beddu/refs/tags/v1.1.0/dist/beddu.sh
    if [ ! -f beddu.sh ]; then
        echo "Failed to download beddu.sh"
        exit 1
    fi
fi

source "./beddu.sh"

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    -r, --repository REPO       Repository name (default: $DEFAULT_REPOSITORY)
    -u, --registry-url URL      Registry URL (default: $REGISTRY_URL)
    -s, --suffixes SUFFIXES     Comma-separated suffixes to delete (e.g., -SNAPSHOT,-dev)
    -m, --min-version VERSION   Minimum version to keep (e.g., 2.0.0)
    -e, --excluded TAGS         Comma-separated tags to exclude (e.g., latest,stable)
    -f, --settings-file FILE    Settings file path (default: settings)
    -i, --interactive           Force interactive mode
    -y, --yes                   Skip confirmation prompts
    -h, --help                  Show this help message

SETTINGS FILE FORMAT:
The settings file should contain key=value pairs:
    REPOSITORY=my-repo
    REGISTRY_URL=my-registry.com
    DELETE_SUFFIXES=-SNAPSHOT,-dev,-test
    MIN_VERSION=2.0.0
    EXCLUDED_TAGS=latest,stable,prod
    AUTO_CONFIRM=true

Command line arguments override settings file values.
EOF
}

# Function to load settings from file
load_settings_file() {
    local settings_file="$1"

    if [[ ! -f "$settings_file" ]]; then
        return 1
    fi

    echo ""
    spin italic grey "Loading settings from $settings_file..."

    # Read file line by line, handling last line without newline
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Validate setting format (VARIABLE=value)
        if [[ "$line" =~ ^[A-Z_][A-Z0-9_]*=.*$ ]]; then
            # Extract variable name and value
            local var_name="${line%%=*}"
            local var_value="${line#*=}"

            # Remove quotes if present
            var_value=$(echo "$var_value" | sed 's/^["'\'']\(.*\)["'\'']$/\1/')

            # Set the variable
            declare -g "$var_name"="$var_value"

            repen spin italic grey "Loaded setting: $var_name=$var_value"
        else
            warning "Invalid setting format in $settings_file: $line"
        fi
    done < "$settings_file"
    check "Finished loading settings from $settings_file"
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--repository)
                REPOSITORY="$2"
                shift 2
                ;;
            -u|--registry-url)
                REGISTRY_URL="$2"
                shift 2
                ;;
            -s|--suffixes)
                IFS=',' read -ra DELETE_SUFFIXES <<< "$2"
                for i in "${!DELETE_SUFFIXES[@]}"; do
                    DELETE_SUFFIXES[$i]=$(echo "${DELETE_SUFFIXES[$i]}" | xargs)
                done
                shift 2
                ;;
            -m|--min-version)
                MIN_VERSION="$2"
                shift 2
                ;;
            -e|--excluded)
                IFS=',' read -ra EXCLUDED_TAGS <<< "$2"
                for i in "${!EXCLUDED_TAGS[@]}"; do
                    EXCLUDED_TAGS[$i]=$(echo "${EXCLUDED_TAGS[$i]}" | xargs)
                done
                shift 2
                ;;
            -f|--settings-file)
                SETTINGS_FILE="$2"
                shift 2
                ;;
            -i|--interactive)
                FORCE_INTERACTIVE=true
                shift
                ;;
            -y|--yes)
                AUTO_CONFIRM=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                warn "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Initialize variables
REPOSITORY=""
DELETE_SUFFIXES=()
MIN_VERSION=""
EXCLUDED_TAGS=()
SETTINGS_FILE="settings"
FORCE_INTERACTIVE=false
AUTO_CONFIRM=false

# Parse command line arguments first
parse_arguments "$@"

# Load settings file (if not overridden by command line)
load_settings_file "$SETTINGS_FILE"

# Set defaults for unset variables
REPOSITORY=${REPOSITORY:-$DEFAULT_REPOSITORY}

# Function to get auth header from Docker config
get_auth_header() {
    local registry=$1
    local auth=$(cat ~/.docker/config.json | jq -r ".auths.\"$registry\".auth")

    if [ "$auth" = "null" ] || [ -z "$auth" ]; then
        warn "Error: No authentication found for $registry" >&2
        throw "Please run: docker login $registry" >&2
        return 1
    fi

    echo "Basic $auth"
}

# Function to compare semantic versions
version_less_than() {
    local version1=$1
    local version2=$2

    # Remove any non-numeric suffixes
    version1=$(echo "$version1" | sed 's/-.*$//')
    version2=$(echo "$version2" | sed 's/-.*$//')

    # Use sort -V for version comparison
    [ "$(printf '%s\n%s' "$version1" "$version2" | sort -V | head -n1)" = "$version1" ] && [ "$version1" != "$version2" ]
}

# Function to check if tag should be excluded
is_excluded_tag() {
    local tag=$1
    for excluded in "${EXCLUDED_TAGS[@]}"; do
        if [ "$tag" = "$excluded" ]; then
            return 0
        fi
    done
    return 1
}

# Function to check if tag has excluded suffix
has_excluded_suffix() {
    local tag=$1
    for suffix in "${DELETE_SUFFIXES[@]}"; do
        if [[ "$tag" == *"$suffix" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to determine if tag should be deleted
should_delete_tag() {
    local tag=$1
    local reason_var=$2

    # Skip if tag is in excluded list
    if is_excluded_tag "$tag"; then
        eval $reason_var="'excluded tag'"
        return 1
    fi

    # Check if tag has a suffix that should be deleted
    if has_excluded_suffix "$tag"; then
        for suffix in "${DELETE_SUFFIXES[@]}"; do
            if [[ "$tag" == *"$suffix" ]]; then
                eval $reason_var="'ends with $suffix'"
                return 0
            fi
        done
    fi

    # Check if tag is a version less than minimum version
    if [ -n "$MIN_VERSION" ] && [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        if version_less_than "$tag" "$MIN_VERSION"; then
            eval $reason_var="'version < $MIN_VERSION'"
            return 0
        fi
    fi

    eval $reason_var="'keeping'"
    return 1
}

# Function to delete image tag
delete_image_tag() {
    local tag=$1
    spin "Deleting tag: $tag"

    # Get manifest digest
    local manifest_response=$(curl -s -v -H "Authorization: $AUTH_HEADER" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://$REGISTRY_URL/v2/$REPOSITORY/manifests/$tag" 2>&1)

    # Extract digest from response headers
    local digest=$(echo "$manifest_response" | grep -i "docker-content-digest" | cut -d' ' -f3 | tr -d '\r')

    if [ -n "$digest" ]; then
        repen spin "  Digest: $digest"
        local delete_response=$(curl -s -w "%{http_code}" -X DELETE -H "Authorization: $AUTH_HEADER" \
            "https://$REGISTRY_URL/v2/$REPOSITORY/manifests/$digest")

        if [[ "$delete_response" =~ 202$ ]]; then
            check "  Successfully deleted: $tag"
        else
            warn "  Failed to delete: $tag (HTTP: $delete_response)"
        fi
    else
        warn "  No digest found for tag: $tag"
    fi
}

# Function to get user input (interactive mode)
get_user_input() {
    pen bold cyan "Docker Registry Cleanup Configuration"
    pen bold cyan "====================================="
    echo ""

    # Get registry URL
    read -p "Enter Docker registry URL (current: $REGISTRY_URL): " input
    REGISTRY_URL=${input:-$REGISTRY_URL}

    # Get repository name
    read -p "Enter repository name (current: $REPOSITORY): " input
    REPOSITORY=${input:-$REPOSITORY}

    # Get suffixes to delete
    echo ""
    echo "Enter suffixes to delete (comma-separated, e.g., -SNAPSHOT,-dev,-test):"
    current_suffixes=$(IFS=,; echo "${DELETE_SUFFIXES[*]}")
    read -p "Suffixes (current: $current_suffixes): " suffixes_input
    if [ -n "$suffixes_input" ]; then
        IFS=',' read -ra DELETE_SUFFIXES <<< "$suffixes_input"
        # Trim whitespace
        for i in "${!DELETE_SUFFIXES[@]}"; do
            DELETE_SUFFIXES[$i]=$(echo "${DELETE_SUFFIXES[$i]}" | xargs)
        done
    fi

    # Get minimum version to keep
    echo ""
    read -p "Enter minimum version to keep (current: ${MIN_VERSION:-"(none)"}): " input
    if [ -n "$input" ]; then
        MIN_VERSION="$input"
    fi

    # Get excluded tags
    echo ""
    echo "Enter specific tags to exclude from deletion (comma-separated):"
    current_excluded=$(IFS=,; echo "${EXCLUDED_TAGS[*]}")
    read -p "Excluded tags (current: $current_excluded): " excluded_input
    if [ -n "$excluded_input" ]; then
        IFS=',' read -ra EXCLUDED_TAGS <<< "$excluded_input"
        # Trim whitespace
        for i in "${!EXCLUDED_TAGS[@]}"; do
            EXCLUDED_TAGS[$i]=$(echo "${EXCLUDED_TAGS[$i]}" | xargs)
        done
    fi
}

# Function to display current configuration
display_configuration() {
    echo ""
    pen bold cyan "Configuration Summary:"
    pen bold cyan "====================="
    pen cyan -n "Repository:                "
    pen bold cyan "$REPOSITORY"
    pen cyan -n "Registry URL:              "
    pen bold cyan "$REGISTRY_URL"
    pen cyan -n "Delete suffixes:           "
    pen bold cyan "${DELETE_SUFFIXES[*]:-"(none)"}"
    pen cyan -n "Minimum version to keep:   "
    pen bold cyan "${MIN_VERSION:-"(none - no version filtering)"}"
    pen cyan -n "Excluded tags:             "
    pen bold cyan "${EXCLUDED_TAGS[*]:-"(none)"}"
    echo ""
}

# Main logic starts here

# Check if we should run in interactive mode
if [ "$FORCE_INTERACTIVE" = true ] || ([ ${#DELETE_SUFFIXES[@]} -eq 0 ] && [ -z "$MIN_VERSION" ] && [ ${#EXCLUDED_TAGS[@]} -eq 0 ]); then
    get_user_input
fi

# Display configuration
display_configuration

# Confirm configuration if not auto-confirmed
if [ "$AUTO_CONFIRM" != "true" ]; then
    read -p "Proceed with this configuration? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        pen bold red "Aborted."
        exit 0
    fi
else
    check "Auto-confirm enabled, proceeding with configuration..."
fi

# Get authentication
AUTH_HEADER=$(get_auth_header "$REGISTRY_URL")
if [ $? -ne 0 ]; then
    exit 1
fi

# List all available tags
echo ""
pen green "Fetching available tags for $REPOSITORY..."
TAGS_RESPONSE=$(curl -s -H "Authorization: $AUTH_HEADER" \
    "https://$REGISTRY_URL/v2/$REPOSITORY/tags/list")

if [ $? -ne 0 ]; then
    throw "Failed to fetch tags"
    exit 1
fi

TAGS=$(echo "$TAGS_RESPONSE" | jq -r '.tags[]' | sort)

if [ -z "$TAGS" ]; then
    throw "No tags found in repository"
    exit 0
fi

pen bold cyan "Available tags:"
echo "$TAGS"
echo ""

# Separate tags into keep and delete arrays
TAGS_TO_KEEP=()
TAGS_TO_DELETE=()
declare -A DELETE_REASONS

for tag in $TAGS; do
    reason=""
    if should_delete_tag "$tag" reason; then
        TAGS_TO_DELETE+=("$tag")
        DELETE_REASONS["$tag"]="$reason"
    else
        TAGS_TO_KEEP+=("$tag")
    fi
done

# Display tags to keep
pen bold green "Tags to KEEP (${#TAGS_TO_KEEP[@]} total):"
pen bold green "========================================"
if [ ${#TAGS_TO_KEEP[@]} -gt 0 ]; then
    for tag in "${TAGS_TO_KEEP[@]}"; do
        pen green "  $tag"
    done
else
    echo "  (none)"
fi
echo ""

# Display tags to delete
pen bold red "Tags to DELETE (${#TAGS_TO_DELETE[@]} total):"
pen bold red "=========================================="
if [ ${#TAGS_TO_DELETE[@]} -gt 0 ]; then
    for tag in "${TAGS_TO_DELETE[@]}"; do
        pen red "  $tag (${DELETE_REASONS[$tag]})"
    done
else
    echo "  (none)"
    echo ""
    throw "No tags to delete. Exiting."
    exit 0
fi
echo ""

# Final confirmation for deletion
if [ "$AUTO_CONFIRM" != "true" ]; then
    read -p "Are you absolutely sure you want to delete ${#TAGS_TO_DELETE[@]} tags? This action cannot be undone. (y/N): " final_confirm
    if [[ ! "$final_confirm" =~ ^[Yy]$ ]]; then
        throw "Aborted."
        exit 0
    fi
fi

check "Proceeding with deletion..."

# Delete the tags
echo ""
pen bold red "Starting deletion process..."
pen bold red "==========================="
DELETED_COUNT=0
for tag in "${TAGS_TO_DELETE[@]}"; do
    warn "Deleting: $tag (${DELETE_REASONS[$tag]})"
    delete_image_tag "$tag"
    ((DELETED_COUNT++))
done

echo ""
check "Deletion complete. Deleted $DELETED_COUNT tags."
warn "Note: Deleting tags may not immediately free up space in the registry due to garbage collection policies."
