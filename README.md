# dkregclean.sh
A bash script to help with cleaning up arbitrary docker registry repositories

## Description
`dkregclean.sh` is a bash script designed to assist in cleaning up Docker registry repositories by deleting tags based on specified criteria. It supports filtering tags by suffixes, minimum (semantic) version, and excluded tags. The script can operate in both interactive and non-interactive modes.  
  
***Please note***:  
* This script uses [beddu.sh](https://github.com/mjsarfatti/beddu) to provide beautified output. The script expects `beddu.sh` to be in the same directory and will download it if not found.
* The script assumes that the Docker registry supports the Docker Registry HTTP API V2.
* The script requires `jq` for JSON parsing and `curl` for HTTP requests.
* The script assumes that the Docker registry allows tag deletion via the API, which may require specific configurations.
* The script works by deleting tags via their digests, which are fetched from the registry. After deletion, the registry may require garbage collection to free up space.

## Features
- Delete tags with specified suffixes (e.g., `-SNAPSHOT`, `-dev`).
- Retain tags that meet or exceed a specified minimum semantic version (e.g., `2.0.0`).
- Exclude specific tags from deletion (e.g., `latest`, `stable`).
- Interactive mode for user confirmation before deletion.
- Non-interactive mode for automated cleanup.
- Configuration via command line arguments or a settings file.

## Usage

```bash
Usage: ./dkregclean.sh [OPTIONS]

OPTIONS:
    -r, --repository REPO       Repository name (default: my-repo)
    -u, --registry-url URL      Registry URL (default: my-registry.com)
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
```
