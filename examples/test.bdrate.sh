#!/bin/bash
set -eu -o pipefail

# First codec used as the BD-rate reference. The ';' delimiter is optional.
CODECS=
CODECS="$CODECS; kingsoft"
CODECS="$CODECS; kingsoft --preset ultrafast"
CODECS="$CODECS; kingsoft --preset superfast"
CODECS="$CODECS; kingsoft --preset fast"
CODECS="$CODECS; x265 kvazaar intel_sw intel_hw h265demo h264demo"

# 4 point required: QP or BR or both
case 0 in
    0)  PRMS="22 27 32 37" # QP        
        VECTORS="akiyo_176x144_30fps.yuv akiyo_352x288_30fps.yuv foreman_176x144_30fps.yuv foreman_352x288_30fps.yuv"
    ;;
    1)  PRMS="500 1000 1500 2000" # BR
        VECTORS="FourPeople_1280x720_30fps.yuv stockholm_ter_1280x720_30fps.yuv vidyo4_1280x720_30fps.yuv"
    ;;
esac

../core/bdrate.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o "bdrate.log" "$@"
