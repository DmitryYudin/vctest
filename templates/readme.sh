#!/bin/bash
set -eu

PRMS_BDRATE_DEFAULT="22 27 32 37"
PRMS_SPEED_DEFAULT=1000
OPTIONS_FILE_DEFAULT=options
usage() {
cat <<-EOT
This script is for internal use only

Scripts from 'codecId' subfolders can be sourced or executed by user scripts

The following environment variables are used:
    Name        Optional    Dafault
    VECTORS       No        -
    CODEC_TST     Yes       same as reference codec
    PRMS          Yes       bdrate: '$PRMS_BDRATE_DEFAULT'; speed: '$PRMS_SPEED_DEFAULT'
    OPTIONS_FILE  Yes       '$OPTIONS_FILE_DEFAULT' (from template subfolder)
EOT
}
(return 0 2>/dev/null) || { usage && exit 0; }
dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )

testId=$(basename ${BASH_SOURCE[1]})
OPTIONS_FILE=${OPTIONS_FILE:-$OPTIONS_FILE_DEFAULT}
CODEC_REF=$(basename ${BASH_SOURCE[1]%$testId})
CODEC_TST=${CODEC_TST:-$CODEC_REF}
CODECS=$CODEC_REF';'
CODECS=$CODECS$(cat $dirScript/$CODEC_REF/$OPTIONS_FILE | sed -r 's/^\s+//; s/#.*//; s/\s+$//g; /^$/d' | awk -v prefix="$CODEC_TST " '{ print prefix $0 }' | tr $'\n' ';')

case $testId in
    bdrate.sh) PRMS=${PRMS:-$PRMS_BDRATE_DEFAULT};;
    speed.sh)  PRMS=${PRMS:-$PRMS_SPEED_DEFAULT};;
esac

# echo "testId=$testId CODEC_REF=$CODEC_REF CODEC_TST=$CODEC_TST PRMS='$PRMS'" && echo "CODECS=$CODECS"

: ${VECTORS?variable not set}
: ${PRMS?variable not set}
echo "[$testId] run with CODEC_REF=$CODEC_REF CODEC_TST=$CODEC_TST PRMS='$PRMS' OPTIONS_FILE='$OPTIONS_FILE' $@"
case $testId in
    bdrate.sh)
        nice -n 10 \
        $dirScript/../core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o bdrate.log --bdrate "$@"
    ;;
    speed.sh)
        $dirScript/../core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o speed.log --ncpu 1 "$@"
    ;;
    *)  echo "error: unknown test '$testId'" && exit 1;;
esac
echo "[$testId] done"
