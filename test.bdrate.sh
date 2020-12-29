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
        VECTORS="akiyo_qcif.yuv foreman_qcif.yuv"
    ;;
    1)  PRMS="500 1000 1500 2000" # BR
        VECTORS="\
            tears_of_steel_1280x720_24.webm.yuv\
            FourPeople_1280x720_30.y4m.yuv\
            stockholm_ter_1280x720_30.y4m.yuv\
            vidyo4_720p_30fps.y4m.yuv\
        "
    ;;
esac
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)

./core/bdrate.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -o "bdrate.log" -r "report" "$@"
