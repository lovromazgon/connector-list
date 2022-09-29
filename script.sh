#!/bin/bash

TMP="./.tmp"
mkdir -p ${TMP}
cd $TMP

# gh wraps the gh cli and adds rate limiting
function gh ()
{
  if [ -z "$rate" ]; then
    # get currently authenticated user rate limit info
    rate=`command gh api rate_limit | jq ".rate"`
  fi

  # decrease remeaning counter
  rate=`jq ".remaining=.remaining-1 | .used=.used+1" <<< $rate`

  # if we don't have at least 10 requests left, wait until reset
  if [ `jq ".remaining" <<< $rate` -lt 10 ]; then
    # fetch reset from API and figure out sleep time
    reset=`jq ".rate.reset" <<< $rate`
    now=`date +%s`
    # sleep until reset
    sleep "$(($reset-$now+1))"
    # refresh rate
    rate=`command gh api rate_limit | jq ".rate"`
  fi

  # execute gh command
  command gh $@
}

# get repos depending on the SDK
gh dependents conduitio/conduit-connector-sdk > dependents.json

# dependents without excluded
jq -s -r "[.[0].dependents[] | .user + \"/\" + .repo] - .[1] | .[]" dependents.json ../.excluded-repos.json > repos.list

# for each repo
while read repo; do
  # get basic repo info
  # TODO store
  # gh repo view conduitio/conduit-connector-file --json nameWithOwner,description,createdAt,url

  # prepare directory it is using
  mkdir -p `dirname releases/${repo}`

  # fetch release list
  gh release list --repo ${repo} > releases/${repo}.list

  # parse release list into JSON
  jq --raw-input --slurp 'split("\n") | map(split("\t")) | .[0:-1] | map( { "tagName": .[0], "type": .[1] } )' releases/${repo}.list > releases/${repo}.json

  # remove list
  rm -f releases/${repo}.list

  # DEBUG (TODO: remove this)
  cat releases/${repo}.json
done < repos.list

# for each release fetch assets
for f in $(find releases -type file -name '*'); do
  basename $f
  echo $f
  cat $f
done



  # # if we don't have at least 10 requests left, wait until reset
  # if ($rate.remaining -lt 10) {
  #     $wait = ($rate.reset - (Get-Date (Get-Date).ToUniversalTime() -UFormat %s))
  #     echo "Rate limit remaining is $($rate.remaining), waiting for $($wait) seconds to reset"
  #     sleep $wait
  #     $rate = gh api rate_limit | convertfrom-json | select -expandproperty rate
  #     echo "Rate limit has reset to $($rate.remaining) requests"
  # }
