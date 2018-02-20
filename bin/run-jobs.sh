#!/bin/bash
#-----------------------------------------------------------------------------
# A simple script to run a number of commands/jobs in parallel
#
# Usage: run-jobs.sh <jobs> <p>
#
#        jobs - a text file containing one command/job per line
#        p    - specifies the number of commands/jobs to run in parallel
#
# Dependencies: bash 4.3 or later
#
# Author: Kristian Loewe
#-----------------------------------------------------------------------------

if [ $# -ne 2 ]; then
  exit 1
fi

jobs=`realpath $1`
p=$2

k=0

n=`wc -l ${jobs} | cut -f1 -d' '`

cat ${jobs} | while read cmd; do

  k=$(( $k+1 ))

  echo "job: $k/$n"
  echo "cmd: ${cmd}"
  eval "${cmd}" & echo "pid: $!"

  sleep 1
  jobs=(`jobs -pr`)

  if [ ${#jobs[@]} -ge $p ]; then
    wait -n # needs bash 4.3 or later
  fi
done

wait

exit 0
