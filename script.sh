#!/bin/bash

#---------------------------------------------------------------------------------------------------
# Script entrypoint
#---------------------------------------------------------------------------------------------------
function main ()
{
  TMP="./.tmp"
  mkdir -p ${TMP}
  cd $TMP

  fetchDependents conduitio/conduit-connector-sdk ../.excluded-repos.json repos.list

  while read repo; do
    # prepare directory it is using
    mkdir -p $repo

    fetchRepoInfo $repo $repo/info.json
    fetchReleaseList $repo $repo/releases.json
    # loop through releases and fetch assets

    # TODO loop through releases
    #   TODO fetch assets and store in $repo/assets/$tagName.json

    # TODO combine $repo/assets/* and $repo/releases.json into connector.json
    # TODO combine info.json and connector.json into connector.json
  done < repos.list
  # TODO combine */connector.json into connectors.json
}

# // connectors.json
# [
#   {
#     // info.json
#     "nameWithOwner":"foo",
#     "description":"foo",
#     "createdAt":"foo",
#     "url":"http://foo",
#     "stargazerCount":123,
#     "forkCount":123,
#     // releases.json
#     "releases": [
#       {
#         "tagName":"v0.1.0",
#         "type":"Latest",
#         // assets/v0.1.0.json
#         "assets": [
#           {
#             // TODO
#           }
#         ]
#       }
#     ]
#   }
# ]

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
  gh dependents $REPO > dependents.tmp

  # dependents without excluded
  jq -s -r "[.[0].dependents[] | .user + \"/\" + .repo] - .[1] | .[]" \
    dependents.tmp $EXCLUDED > $FILE_OUT

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
  gh repo view $REPO \
    --json nameWithOwner,description,createdAt,url,stargazerCount,forkCount \
    > $FILE_OUT
}


#---------------------------------------------------------------------------------------------------
# Fetch list of releases
#
# Parameters
# 1 Repository name (e.g. conduitio/conduit-connector-file)
# 2 Output file
#---------------------------------------------------------------------------------------------------
function fetchReleaseList ()
{
  local -r REPO=${1}
  local -r FILE_OUT=${2}

  # get list of releases and transform it into json
  gh release list --repo $REPO | \
    jq --raw-input --slurp 'split("\n") | map(split("\t")) | .[0:-1] | map( { "tagName": .[0], "type": .[1] } )' \
    > $FILE_OUT
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
    RATE_LIMIT=`command gh api rate_limit | jq ".rate"`
  fi

  # decrease remeaning counter
  RATE_LIMIT=`jq ".remaining=.remaining-1 | .used=.used+1" <<< $RATE_LIMIT`

  # if we don't have at least 10 requests left, wait until reset
  if [ `jq ".remaining" <<< $RATE_LIMIT` -lt 10 ]; then
    # take reset time from API response and figure out sleep time
    local -r RESET=`jq ".rate.reset" <<< $RATE_LIMIT`
    local -r NOW=`date +%s`
    # sleep until reset
    sleep "$(($RESET-$NOW+1))"
    # refresh rate
    RATE_LIMIT=`command gh api rate_limit | jq ".rate"`
  fi

  # execute gh command
  command gh $@
}

# run script
main
