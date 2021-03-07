import os, sys, getopt
import bjontegaard_metric

def usage():
    name=os.path.basename(sys.argv[0])
    print("usage: %s -r \"kbps0 ... kbps3\" -p \"psnr0 ... psnr3\" -r \"...\" -p \"...\"" % name)
    print("    -h                - This help")
    print("    -b <rate_list>    - List of bitrates in kbps")
    print("    -p <psnr_list>    - List of PSNR values")
    print("    --ref <rate psnr> - Pair of values for the reference codec")
    print("    --tst <rate psnr> - Pair of values for the cdec under test")
    print("Note, acceptable separators are: comma, semicolon or whitespace.")
    print("The first sequence of rates/psnr values considered as the reference.")
    print("Example:")
    print("    %s \\" % name)
    print("            -b \"40433.88 7622.75 2394.49 1017.62\" -p 37.58,35.38,33.90,32.06 \\")
    print("            -b \"40370.12;7587.00;2390.00;1017.10\" -p37.60,35.40,33.92,32.08")
    print("    %s \\" % name)
    print("            --ref 40433.88,37.58 --ref7622.75,35.38 --ref\"2394.49 33.90\" --ref\"1017.62 32.06\" \\")
    print("            --tst 40370.12,37.60 --tst7587.00,35.40 --tst\"2390.00 33.92\" --tst\"1017.10 32.08\"")

def error_exit(msg):
    if msg != None:
        sys.stderr.write ("Error: %s\n" % msg)
    sys.exit(1)

def flatmap(f, l): # https://stackoverflow.com/questions/11264684/flatten-list-of-lists
    return [y for sublist in map(f, l) for y in sublist]

def split_string_of_float(input):
    result = [input]
    for delim in [' ', ',', ';' ]:
        result = flatmap(lambda x: x.split(delim), result)
    result = [i for i in result if i] # remove empty
    result = [float(x) for x in result]
    return result

def main():
    ref_bitrate = []
    ref_psnr = []
    tst_bitrate = []
    tst_psnr = []

    try:
        opts, args = getopt.gnu_getopt(sys.argv[1:], "hb:p:", ["help", "ref=", "tst="])
    except getopt.GetoptError as err:
        usage()
        error_exit(err)

    if len(opts) == 0:
        usage()
        sys.exit(1)

    for opt, arg in opts:        
        if opt in ("-h", "--help"):
            usage()
            sys.exit()
        elif opt in ("-b",):
            values = split_string_of_float(arg)
            if not ref_bitrate:
                ref_bitrate = values
            elif not tst_bitrate:
                tst_bitrate = values
            else:
                error_exit("too many bitrate values")
        elif opt in ('-p',):
            values = split_string_of_float(arg)
            if not ref_psnr:
                ref_psnr = values
            elif not tst_psnr:
                tst_psnr = values
            else:
                error_exit("too many PSNR values")
        elif opt in ("--ref",):
            values = split_string_of_float(arg)
            ref_bitrate.append(values[0])
            ref_psnr.append(values[1])
        elif opt in ("--tst",):
            values = split_string_of_float(arg)
            tst_bitrate.append(values[0])
            tst_psnr.append(values[1])

    if len(ref_bitrate) != 4:
        error_exit("expected 4 bitrate values (%s), but %d values given" % ('ref', len(ref_bitrate)))
    if len(tst_bitrate) != 4:
        error_exit("expected 4 bitrate values (%s), but %d values given" % ('tst', len(tst_bitrate)))
    if len(ref_psnr) != 4:
        error_exit("expected 4 PSNR values (%s), but %d values given" % ('ref', len(ref_psnr)))
    if len(tst_psnr) != 4:
        error_exit("expected 4 PSNR values (%s), but %d values given" % ('tst', len(tst_psnr)))

    bdrate = bjontegaard_metric.BD_RATE(ref_bitrate, ref_psnr, tst_bitrate, tst_psnr);
    bdpsnr = bjontegaard_metric.BD_PSNR(ref_bitrate, ref_psnr, tst_bitrate, tst_psnr);
    print ("BD-rate:%f BD-PSNR:%f" % (bdrate, bdpsnr))

if __name__ == "__main__":
    main()

# -b "40433.88, 7622.75, 2394.49, 1017.62" -p "37.58, 35.38, 33.90, 32.06" -b"40370.12, 7587.00, 2390.0, 1017.10" -p"37.60, 35.40, 33.92, 32.08"
# -b "14265.54  5016.52  1692.18   834.53" -p" 40.52  38.21  36.52  34.82" -b"10779.78  3764.73  1350.1  665.00" -p "39.74 37.87 36.43 34.89"
