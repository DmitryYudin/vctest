#!/bin/bash
set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )

$dirScript/testbench.sh --bdrate "$@"
