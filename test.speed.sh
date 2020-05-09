set -eu -o pipefail

CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
#CODECS=h265demo

#QP="28 34 39 44"
BITRATE="1500 2000 3000 4000"; 
VECTORS=""
VECTORS="$VECTORS tears_of_steel_1280x720_24.webm.yuv"
VECTORS="$VECTORS FourPeople_1280x720_30.y4m.yuv"
VECTORS="$VECTORS stockholm_ter_1280x720_30.y4m.yuv"
VECTORS="$VECTORS vidyo4_720p_30fps.y4m.yuv"

VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)
./core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "${QP:-} ${BITRATE:-}" -o report/report.log "$@" --ncpu 1
