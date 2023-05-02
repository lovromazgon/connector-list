#!/bin/bash

#---------------------------------------------------------------------------------------------------
# Script entrypoint
#---------------------------------------------------------------------------------------------------
function main ()
{
  FILE_OUT="connectors.json"
  TMP="./.tmp"
  REPO_SDK="conduitio/conduit-connector-sdk"

  mkdir -p "$TMP"
  cd "$TMP" || exit 1

  fetchDependents $REPO_SDK ../.excluded-repos.json repos.list
  log ""

  while read -r repo; do
    # prepare repo directory
    mkdir -p "$repo"
    cd "$repo" || exit 2

    log "Processing $repo"

    log "- 📥 Fetching repository information..."
    fetchRepoInfo "$repo" "info.json"

    log "- 📥 Fetching releases..."
    fetchReleases "$repo" "releases-raw.json"

    log "- 🔨 Processing releases..."
    processReleases "releases-raw.json" "releases.json"

    log "- 🪚 Building connector.json..."
    buildConnectorInfo "info.json" "releases.json" "connector.json"

    log "✅ $repo processed"
    log ""

    # move out of repo directory, it's 2 levels deep (org/repo)
    cd ../..
  done < repos.list

  # move outside of TMP
  cd ..

  log "Building connectors.json..."
  # shellcheck disable=SC2038
  # combine all */connector.json files into connectors.json
  find "$TMP" -name "connector.json" | xargs jq -s '.' > "connectors.json"

  log "Removing temporary folder..."
  # remove TMP
  rm -rf "$TMP"

  log "✅ Done"
}

#---------------------------------------------------------------------------------------------------
# Fetch dependents
#
# Parameters
# 1 Repository name (e.g. conduitio/conduit-connector-sdk)
# 2 Path to file containing excluded dependents (e.g. ../.excluded-repos.json)
# 3 Output file
#---------------------------------------------------------------------------------------------------
function fetchDependents ()
{
  local -r REPO=${1}
  local -r EXCLUDED=${2}
  local -r FILE_OUT=${3}

  # get repos depending on the SDK
  log "Fetching dependents..."
  gh dependents "$REPO" > dependents.tmp

  # dependents without excluded
  log "Removing excluded dependents..."
  jq -s -r "[.[0].dependents[] | .user + \"/\" + .repo] - .[1] | .[]" \
    dependents.tmp "$EXCLUDED" > "$FILE_OUT"

  DEPENDENTS_COUNT_ALL=$(jq ".dependents | length" dependents.tmp)
  DEPENDENTS_COUNT_FILTERED=$(printf %d "$(wc -l <"$FILE_OUT")")
  log "Fetched $DEPENDENTS_COUNT_FILTERED dependents (excluded $((DEPENDENTS_COUNT_ALL-DEPENDENTS_COUNT_FILTERED)))"

  # remove temporary file
  rm dependents.tmp
}

#---------------------------------------------------------------------------------------------------
# Fetch repository information
#
# Parameters
# 1 Repository name (e.g. conduitio/conduit-connector-file)
# 2 Output file
#---------------------------------------------------------------------------------------------------
function fetchRepoInfo ()
{
  local -r REPO=${1}
  local -r FILE_OUT=${2}

  # get basic repo info
  gh repo view "$REPO" \
    --json nameWithOwner,description,createdAt,url,stargazerCount,forkCount \
    > "$FILE_OUT"
}

#---------------------------------------------------------------------------------------------------
# Fetch releases and store them in a JSON file
#
# Parameters
# 1 Repository name (e.g. conduitio/conduit-connector-file)
# 2 Output file
#---------------------------------------------------------------------------------------------------
function fetchReleases ()
{
  local -r REPO=${1}
  local -r FILE_OUT=${2}

  gh api "/repos/$REPO/releases" > "$FILE_OUT"
}

#---------------------------------------------------------------------------------------------------
# Process releases, extract OS/ARCH info for each asset and filter unknown OS/ARCH combinations
#
# Parameters
# 1 Path to releases JSON file (e.g. conduitio/conduit-connector-file/releases.json)
# 2 Output file
#---------------------------------------------------------------------------------------------------
function processReleases ()
{
  local -r RELEASES_JSON=${1}
  local -r FILE_OUT=${2}

  # extract os and arch from filename of each asset
  jq 'map(
    .tag_name[1:] as $version |
    .assets |= map(
      (
        .name[
          (.name | index($version)) +
          ($version | length)
          +1:
        ] |
        split(".")[0]
      ) as $osarch |
      . + {
        os: ($osarch | split("_")[0]),
        arch: ($osarch | split("_")[1:] | join("_"))
      }
    )
  )' "$RELEASES_JSON" > releases-1.tmp

  # map os and arch values so they match the values used by Go
  jq --argjson mapping '{"x86_64":"amd64","i386":"386"}' \
    'map(
      .assets |= map(
        .arch |= (
          if $mapping[.] != null then $mapping[.]
          else .
          end
        ) |
        .os |= ascii_downcase
      )
    )' releases-1.tmp > releases-2.tmp

  # GOOS and GOARCH values taken from https://github.com/golang/go/blob/master/src/go/build/syslist.go
  GOOS_ARRAY='["aix","android","darwin","dragonfly","freebsd","hurd","illumos","ios","js","linux","nacl","netbsd","openbsd","plan9","solaris","wasip1","windows","zos"]'
  GOARCH_ARRAY='["386","amd64","amd64p32","arm","armbe","arm64","arm64be","loong64","mips","mipsle","mips64","mips64le","mips64p32","mips64p32le","ppc","ppc64","ppc64le","riscv","riscv64","s390","s390x","sparc","sparc64","wasm"]'

  # filter assets with unknown OS and ARCH
  jq --argjson goos "$GOOS_ARRAY" \
     --argjson goarch "$GOARCH_ARRAY" \
    'map(
      .assets |= map(
        select(.os as $os | $goos | index($os)) |
        select(.arch as $arch | $goarch | index($arch))
      )
    )' releases-2.tmp > "$FILE_OUT"

  # remove temporary files
  rm releases-1.tmp
  rm releases-2.tmp
}

#---------------------------------------------------------------------------------------------------
# Combine repository info and releases into connector info JSON
#
# Parameters
# 1 Path to repository info JSON file (e.g. conduitio/conduit-connector-file/info.json)
# 2 Path to releases JSON file (e.g. conduitio/conduit-connector-file/releases.json)
# 3 Output file
#---------------------------------------------------------------------------------------------------
function buildConnectorInfo ()
{
  local -r INFO_JSON=${1}
  local -r RELEASES_JSON=${2}
  local -r FILE_OUT=${3}

  RELEASE_FIELDS="tag_name, name, body, draft, prerelease, published_at, html_url, assets"
  ASSET_FIELDS="name, os, arch, content_type, browser_download_url, created_at, updated_at, download_count, size"

  jq -s ".[0] + {releases: .[1]} | .releases |= map({$RELEASE_FIELDS}) | .releases[].assets |= map({$ASSET_FIELDS})" \
    "$INFO_JSON" "$RELEASES_JSON" \
    > "$FILE_OUT"
}

#---------------------------------------------------------------------------------------------------
# Run gh CLI with rate limiting
#
# All parameters will be passed to gh cli
#---------------------------------------------------------------------------------------------------
function gh ()
{
  if [ -z "$RATE_LIMIT" ]; then
    # get currently authenticated user rate limit info
    RATE_LIMIT=$(command gh api rate_limit | jq ".rate")
  fi

  # decrease remeaning counter
  RATE_LIMIT=$(jq ".remaining=.remaining-1 | .used=.used+1" <<< "$RATE_LIMIT")

  # if we don't have at least 10 requests left, wait until reset
  if [ "$(jq ".remaining" <<< "$RATE_LIMIT")" -lt 10 ]; then
    # take reset time from API response and figure out sleep time
    local -r RESET=$(jq ".rate.reset" <<< "$RATE_LIMIT")
    local -r NOW=$(date +%s)
    # sleep until reset
    sleep "$((RESET-NOW+1))"
    # refresh rate
    RATE_LIMIT=$(command gh api rate_limit | jq ".rate")
  fi

  # execute gh command
  # shellcheck disable=SC2068
  command gh $@
}

#---------------------------------------------------------------------------------------------------
# Log a message to stderr
#
# All parameters will be printed as a string using printf
#---------------------------------------------------------------------------------------------------
function log ()
{
  printf "%s\n" "$*" >&2;
}

# run script
main
